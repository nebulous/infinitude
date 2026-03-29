package CarBus::SAM;
use strict;
use warnings;
use feature ':5.10';
use Moo;
use Data::ParseBinary;
use CarBus::Frame;
use CHI;

has bus => (is => 'ro', required => 1);
has store => (is => 'ro', default => sub {
    CHI->new(driver => 'File', root_dir => 'state/sam-emulator', depth => 0)
});
has handlers => (is => 'ro', default => sub { {} });

# Register storage - backed by CHI store
sub registers {
    my $self = shift;
    return $self->store->get('registers') // {};
}

sub set_register {
    my ($self, $key, $value) = @_;
    my $regs = $self->registers;
    $regs->{$key} = $value;
    $self->store->set('registers', $regs);
}

sub get_register {
    my ($self, $key) = @_;
    return $self->registers->{$key};
}

# Real SAM device info (observed from SYSTXCCSAM01)
# device:    "SYSTEM ACCESS MODULE"
# software:  "CESR131379-03"
# model:     "SYSTXCCSAM01"
# serial:    "1009N182206"
#
# Compatible devices (from Carrier SAM01-04XA spec):
# - SYSTXCCSAM01, SYSTXCCRCT01, SYSTXNNRCT01, SYSTXCCRWF01
# - Legacy UID/UIZ controls: firmware 14+
# - Infinity Touch controls: firmware 08+

# Registers SAM polls FROM thermostat (observed in traffic):
# These are THERMOSTAT registers, not SAM registers
# 0x02xx - Time/date registers (0202=time, 0203=date)
# 0x03xx - Status registers (030D appears in both SAM and thermostat)
# 0x30xx - Unknown thermostat registers (3003, 3005, 3104)
# 0x3Cxx - Unknown thermostat registers (3c0c, 3c0d, 3c14) - mostly return exceptions
# 0x04xx - Sync/status registers (0420 appears after setpoint changes)
#
# Note: The SAM appears to cache thermostat data in its own 3Bxx registers
# rather than accessing thermostat registers directly.

# Register SAM parsers with Frame.pm on module load

# 0104 - Device info register (read-only, 120 bytes)
# Standard device identification: device name, software version, model, serial
# No parser registered - handled specially by spoof_device_info if needed

# 030D - SAM status register (read-only, 7 bytes)
# Observed values: 61, 62, 63, 0, 0, 0, 0 (ASCII "=", ">", "?")
# Purpose unknown - possibly version/status codes
CarBus::Frame->add_parser('030D', Struct('sam_status',
    Byte('val1'),      # Observed: 61 (0x3d)
    Byte('val2'),      # Observed: 62 (0x3e)
    Byte('val3'),      # Observed: 63 (0x3f)
    Byte('reserved1'),
    Byte('reserved2'),
    Byte('reserved3'),
    Byte('reserved4'),
));

# 3B02 - System state register (read-only)
# Contains current mode, temperatures, time, and zone occupancy
# Note: On Touch controls, unoccupied maps to AWAY state in "hold permanent"
CarBus::Frame->add_parser('3B02', Struct('sam_state',
    Byte('active_zones'),
    Padding(2),
    Array(8, Byte('temperature')),       # Room temp per zone (F or C based on units)
    Array(8, Byte('humidity')),          # Room humidity per zone (max 99%)
    Padding(1),
    Byte('oat'),                         # Outdoor air temperature
    BitStruct('zones_unoccupied',        # Touch: maps to AWAY in "hold permanent"
        Flag('z8'), Flag('z7'), Flag('z6'), Flag('z5'),
        Flag('z4'), Flag('z3'), Flag('z2'), Flag('z1'),
    ),
    BitStruct('stagmode',                # High nibble: stage#, Low nibble: mode
        Nibble('stage'),                 # Number of active heating/cooling stages
        Enum(Nibble('mode'), heat=>0, cool=>1, auto=>2, eheat=>3, off=>4)
    ),
    Array(2, Byte('unknown')),
    Enum(Byte('weekday'), Sunday=>0, Monday=>1, Tuesday=>2, Wednesday=>3, Thursday=>4, Friday=>5, Saturday=>6),
    UBInt16('minutes_since_midnight'),   # Time as minutes since midnight
    Byte('displayed_zone')               # Zone currently shown on thermostat (1-8)
));

# 3B03 - Zone settings register (read-write)
# Contains per-zone setpoints, fan modes, hold status, and names
# Note: zone_name is 11 chars + NUL = 12 bytes
# Touch: AUTO fan means continuous fan OFF; HOLD is "hold permanent"
CarBus::Frame->add_parser('3B03', Struct('sam_zones',
    Byte('active_zones'),
    Padding(2),
    Array(8, Enum(Byte('fan_mode'), high=>3, medium=>2, low=>1, auto=>0 )),
    BitStruct('zones_holding',           # Touch: "hold permanent" status
        Flag('z8'), Flag('z7'), Flag('z6'), Flag('z5'),
        Flag('z4'), Flag('z3'), Flag('z2'), Flag('z1'),
    ),
    Array(8, Byte('heat_setpoint')),     # Heat setpoint per zone
    Array(8, Byte('cool_setpoint')),     # Cool setpoint per zone
    Array(8, Byte('humidity_setpoint')), # Humidification target per zone (max 99%)
    Byte('speed_controlled_fan'),
    Byte('hold_timer'),
    Array(8, UBInt16('hold_duration')),  # "Hold until" duration in minutes
    Array(8, Field('zone_name', 12))     # 11 chars max + NUL terminator
));

# 3B04 - Vacation settings register (read-write)
# Max vacation: 365 days (8760 hours)
# Vacation humidity valid values:
#   Legacy: min=0,10,15,20; max=55,60,65,100(NONE)
#   Touch:  min=0(NONE),5,10,15,20,25,30,35,40,45; max=50,55,60,65,100(NONE)
CarBus::Frame->add_parser('3B04', Struct('sam_vacation',
    Byte('active'),
    UBInt16('hours'),                    # Duration in hours (max 8760 = 365 days)
    Byte('min_temp'),                    # Min vacation temperature
    Byte('max_temp'),                    # Max vacation temperature
    Byte('min_humidity'),                # Min vacation humidity (0 = NONE)
    Byte('max_humidity'),                # Max vacation humidity (100 = NONE)
    Enum(Byte('fan_mode'), high=>3, medium=>2, low=>1, auto=>0 )
));

# 3B05 - Accessory life and reminders register (read-only)
# Contains consumption percentages and reminder flags for accessories
# Values are 0-100% consumption (0 = new/reset, 100 = replace)
CarBus::Frame->add_parser('3B05', Struct('sam_accessories',
    Padding(3),
    Byte('filter_consumption'),          # Filter life used % (reset with !0)
    Byte('uv_consumption'),              # UV lamp life used % (reset with !0)
    Byte('humidifier_consumption'),      # Humidifier pad life used % (reset with !0)
    Byte('ventilator_consumption'),      # Ventilator filter life used % (reset with !0)
    Enum(Byte('filter_reminders'), off=>0, on=>1),
    Enum(Byte('uv_reminders'), off=>0, on=>1),
    Enum(Byte('humidifier_reminders'), off=>0, on=>1),
    Enum(Byte('ventilator_reminders'), off=>0, on=>1),
));

# 3B06 - Dealer info and configuration register (read-write)
# dealer_name/dealer_phone: max 18 chars each (Touch: set via online/USB only)
# temp_units: Query returns F/C, Set uses E (English) or M (Metric)
# Touch-specific: CFGAUTO, CFGDEAD, CFGCPH set commands return NAK
# Touch backlight: ON=level>=3, OFF=level<=2; Set ON->Level8, OFF->Level2
CarBus::Frame->add_parser('3B06', Struct('sam_dealer',
    Byte('backlight'),                   # ON/OFF (Touch: level-based)
    Byte('auto_mode'),                   # Auto mode enabled (Touch: set returns NAK)
    Padding(1),
    Byte('deadband'),                    # Heat/cool deadband 0-6 (Touch: set returns NAK)
    Byte('cycles_per_hour'),             # CPH 2-6 (Touch: set returns NAK)
    Byte('schedule_periods'),            # Periods per day 2 or 4 (Touch: returns NAK)
    Byte('programs_enabled'),            # Programming enabled (Touch: set returns NAK)
    Byte('temp_units'),                  # F=English, C=Metric (set with E/M)
    Pointer(15, CString('dealer_name')), # Max 18 chars (Touch: set returns NAK)
    Pointer(35, CString('dealer_phone')),# Max 18 chars (Touch: set returns NAK)
));

# Set up callback handlers for emulation
sub on_read {
    my ($self, $reg, $handler) = @_;
    $self->handlers->{$reg}->{read} = $handler;
}

sub on_write {
    my ($self, $reg, $handler) = @_;
    $self->handlers->{$reg}->{write} = $handler;
}

# Handle incoming frame addressed to SAM
sub handle_frame {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;

    return unless $fs->{dst} eq 'SAM' || $fs->{dst} eq 'FakeSAM';

    if ($fs->{cmd} eq 'read') {
        return $self->_handle_read($frame);
    }
    elsif ($fs->{cmd} eq 'write') {
        return $self->_handle_write($frame);
    }
    return;
}

sub _handle_read {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $reg_key = sprintf("%02X%02X", $table, $row);

    # Try uppercase first (handler key), then lowercase (reg_string style)
    my $handler = $self->handlers->{$reg_key}->{read} // $self->handlers->{lc($reg_key)}->{read};
    my $data = $handler ? $handler->() : ($self->get_register($reg_key) // $self->get_register(lc($reg_key)));

    return unless defined $data;

    # Build reply frame
    return CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => pack("C*", 0, $table, $row) . $data,
    );
}

sub _handle_write {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $value = substr($fs->{payload_raw}, 3);
    my $reg_key = sprintf("%02X%02X", $table, $row);

    # Try uppercase first (handler key), then lowercase (reg_string style)
    my $handler = $self->handlers->{$reg_key}->{write} // $self->handlers->{lc($reg_key)}->{write};
    if ($handler) {
        $handler->($value);
    } else {
        $self->set_register($reg_key, $value);
        $self->set_register(lc($reg_key), $value);  # Store both cases for consistency
    }

    # Send ack reply
    return CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => $fs->{payload_raw},
    );
}

# Convenience: read from thermostat
sub read_thermostat {
    my ($self, $table, $row) = @_;
    return $self->bus->read_register('Thermostat', $table, $row);
}

# Convenience: write to thermostat
sub write_thermostat {
    my ($self, $table, $row, $value) = @_;
    return $self->bus->write_register('Thermostat', $table, $row, $value);
}

# Handler to spoof SAM device_info responses (register 0104)
# Usage: push @{$bus->handlers}, \&CarBus::SAM::spoof_device_info;
# Intercepts SAM replies and rewrites device info to identify as infinitude
sub spoof_device_info {
    my ($bus, $frame) = @_;
    my $fs = $frame->struct;

    return unless $fs->{src} eq 'SAM';
    return unless $fs->{cmd} eq 'reply';
    return unless $fs->{reg_string} eq '0104';

    my $infop = CarBus::Frame::subparser($fs->{reg_string});
    my $data = { %{$fs->{payload}//{}} };
    $data->{location} = 'github/nebulous';
    $data->{model} = 'INFINITUDE01';
    $data->{software} = 'infinitude';
    $frame->frame({ payload_raw => pack("H*", "000104") . $infop->build($data) });
}

1;
