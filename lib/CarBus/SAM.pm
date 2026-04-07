package CarBus::SAM;
use Moo;

has bus => (is => 'ro', required => 1);
has store => (is => 'ro', default => sub {
    CHI->new(driver => 'File', root_dir => 'state/sam-emulator', depth => 0)
});
has handlers => (is => 'ro', default => sub { {} });
has emulated_src => (is => 'ro', default => 'FakeSAM');

sub handler {
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

# Learn a register value from observed real SAM traffic
sub learn_register {
    my ($self, $reg_key, $raw_data) = @_;
    $reg_key = lc($reg_key);
    my $existing = $self->get_register($reg_key);
    if (!defined $existing) {
        $self->set_register($reg_key, $raw_data);
        return 1;  # Learned new register
    }
    return 0;  # Already known
}

# Return list of registers the emulator knows about
sub known_registers {
    my ($self) = @_;
    return [keys %{$self->registers}];
}

# Initialize default register values if store is empty
sub initialize_defaults {
    my $self = shift;

    # Skip if registers already exist
    return if $self->store->get('registers');

    # Get parsers for building register data
    my $device_info_parser = CarBus::Frame::subparser('0104');
    my $sam_status_parser = CarBus::Frame::subparser('030D');
    my $state_parser = CarBus::Frame::subparser('3B02');
    my $zones_parser = CarBus::Frame::subparser('3B03');

    # Register 0104 - Device info (uses configured device_identity)
    $self->set_register('0104', $device_info_parser->build($self->device_identity));

    # Register 030D - SAM status
    $self->set_register('030d', $sam_status_parser->build({
        val1 => 61, val2 => 62, val3 => 63,
        reserved1 => 0, reserved2 => 0, reserved3 => 0, reserved4 => 0,
    }));

    # Register 3B02 - System state
    $self->set_register('3b02', $state_parser->build({
        active_zones => 0x01,
        temperature => [(70) x 8],
        humidity => [(50) x 8],
        oat => 70,
        zones_unoccupied => {
            z1 => 0, z2 => 0, z3 => 0, z4 => 0,
            z5 => 0, z6 => 0, z7 => 0, z8 => 0,
        },
        stagmode => { stage => 0, mode => 'off' },
        unknown => [0, 0],
        weekday => 'Monday',
        minutes_since_midnight => 480,
        displayed_zone => 1,
    }));

    # Register 3B03 - Zone settings
    $self->set_register('3b03', $zones_parser->build({
        active_zones => 0x01,
        fan_mode => [('auto') x 8],  # auto
        zones_holding => {
            z1 => 0, z2 => 0, z3 => 0, z4 => 0,
            z5 => 0, z6 => 0, z7 => 0, z8 => 0,
        },
        heat_setpoint => [(68) x 8],
        cool_setpoint => [(76) x 8],
        humidity_setpoint => [(50) x 8],
        speed_controlled_fan => 0,
        hold_timer => 0,
        hold_duration => [(0) x 8],
        zone_name => [map { "Zone $_\0" . ("\0" x (12 - length("Zone $_") - 1)) } 1..8],
    }));

    # Register 3B04 - Vacation settings (default: vacation off)
    my $vacation_parser = CarBus::Frame::subparser('3B04');
    $self->set_register('3b04', $vacation_parser->build({
        active => 0,
        hours => 0,
        min_temp => 60,
        max_temp => 85,
        min_humidity => 0,
        max_humidity => 100,
        fan_mode => 'auto',
    }));

    # Register 3B05 - Accessory life and reminders (default: all new/reset)
    my $accessories_parser = CarBus::Frame::subparser('3B05');
    $self->set_register('3b05', $accessories_parser->build({
        filter_consumption => 0,
        uv_consumption => 0,
        humidifier_consumption => 0,
        ventilator_consumption => 0,
        filter_reminders => 'off',
        uv_reminders => 'off',
        humidifier_reminders => 'off',
        ventilator_reminders => 'off',
    }));

    # Register 3B06 - Dealer info and configuration
    my $dealer_parser = CarBus::Frame::subparser('3B06');
    $self->set_register('3b06', $dealer_parser->build({
        backlight => 8,
        auto_mode => 1,
        deadband => 3,
        cycles_per_hour => 4,
        schedule_periods => 4,
        programs_enabled => 1,
        temp_units => ord('F'),
        dealer_name => '',
        dealer_phone => '',
    }));

    # Register 3B0E - Activity flag
    $self->set_register('3b0e', pack("C", 0));
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
# 0x3Cxx - Unknown registers SAM polls (3c0c, 3c0d, 3c14) — always return exception 0x04 from thermostat.
#   These registers are NOT served by any device. They may be SAM-internal registers
#   that a real SAM would answer to its own reads. Our emulator reads them but
#   gets no data back. SAM queries these in bursts AFTER ASCII commands, likely
#   to verify change propagation. See timed-override capture (2026-04-01):
#   3C14 queried 228 times, 3C0C 159 times, 3C0D 151 times during a 3-hour run.
#   The 54,076 exceptions in a 10.5hr passive capture are the thermostat
#   saying "I don't serve this register." NOT a failure.
# 0x04xx - Sync/status registers (0420 polled routinely by SAM but never observed during
#   override/setpoint commands — likely routine background polling, not setpoint-linked)
#
# Change notification flow (ASCII set commands):
#   ASCII cmd → SAM → ACK on ASCII port
#                → SAM updates internal register (3B06, 3B03, etc)
#                → SAM notifies Thermostat via ABCD bus (writes 3B03 to thermostat)
#                → Thermostat writes 3B0E (activity flag) back to SAM
#                → Thermostat reads 0104 + 030D
#   Config changes (BLIGHT): 3 × 3B0E, ~3s latency, ~4s total activity
#   Zone commands (HTSP, FAN): ~11 × 3B0E, 0.7-12s latency, ~17s total activity
#
# Direct CarBus writes to SAM registers do NOT trigger this notification flow.
# The SAM caches the value but does not notify the thermostat.

# Register SAM parsers with Frame.pm on module load

# 0104 - Device info register (read-only, 120 bytes)
# Standard device identification: device name, software version, model, serial
# Built from device_identity attribute in initialize_defaults()

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

# 3B0E - Thermostat activity indicator (write-only from thermostat)
# Thermostat writes 0x01 to this register after the SAM notifies it of a change
# via the ABCD bus (e.g., after an ASCII set command like BLIGHT!ON or HTSP!66).
# This is the thermostat's acknowledgment that it processed the SAM's notification.
# NOT triggered by direct CarBus writes to SAM registers — only by ASCII-initiated changes.
#
# Intensity varies by change type (tested 2026-03-30):
#   System commands (BLIGHT): 3 × 3B0E in single burst, first at +3.3s
#   Zone commands (HTSP, FAN): ~11 × 3B0E in spread bursts of 3
#   Queued/overlapping: 20-50 compressed 3B0E writes
#   Each burst is exactly 3 writes (triplication for reliability)
CarBus::Frame->add_parser('3B0E', Struct('sam_activity',
    Byte('flag'),  # Observed: 0x01
));

# 0420 - Sync/status register (20 bytes, mostly zeros)
# NEVER observed as a SAM register in 8-command protocol test (2026-03-30).
# This is likely a THERMOSTAT register that the SAM polls, not a SAM register.
# Parser kept for frame decoding of thermostat-originated traffic.
CarBus::Frame->add_parser('0420', Struct('sam_sync',
    Array(20, Byte('data')),  # All zeros observed
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

    return unless defined $fs->{dst} && ($fs->{dst} eq 'SAM' || $fs->{dst} eq 'FakeSAM');

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
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));

    my $handler = $self->handlers->{$reg_key}->{read};
    my $data = $handler ? $handler->() : $self->get_register($reg_key);

    if (defined $data) {
        return CarBus::Frame->new(
            src     => $self->emulated_src,
            src_bus => $fs->{dst_bus},
            dst     => $fs->{src},
            dst_bus => $fs->{src_bus},
            cmd     => 'reply',
            payload_raw => pack("C*", 0, $table, $row) . $data,
        );
    }

    return $self->_exception_reply($frame, 0x04);
}

sub _handle_write {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $value = substr($fs->{payload_raw}, 3);
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));

    my $handler = $self->handlers->{$reg_key}->{write};
    if ($handler) {
        $handler->($value);
    } else {
        $self->set_register($reg_key, $value);
    }

    # Send ack reply
    return CarBus::Frame->new(
        src     => $self->emulated_src,
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => $fs->{payload_raw},
    );
}

sub _exception_reply {
    my ($self, $frame, $code) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    return CarBus::Frame->new(
        src     => $self->emulated_src,
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'exception',
        payload_raw => pack("C*", 0, $table, $row, $code),
    );
}

# Convenience: read from thermostat
sub read_thermostat {
    my ($self, $table, $row) = @_;
    return $self->bus->read_register('Thermostat', $table, $row, {src => $self->emulated_src});
}

# Convenience: write to thermostat
sub write_thermostat {
    my ($self, $table, $row, $value) = @_;
    return $self->bus->write_register('Thermostat', $table, $row, $value, {src => $self->emulated_src});
}

# Notify thermostat of a register change (emulates SAM's post-ASCII bus notification)
#
# After the real SAM accepts an ASCII command, it notifies the thermostat via
# the ABCD bus. The thermostat responds by writing 3B0E (activity flag) back.
# This method triggers the same notification flow from the emulator.
sub notify_change {
    my ($self, $reg_key) = @_;

    my $data = $self->get_register($reg_key);
    return unless defined $data;

    # Parse register key into table/row bytes
    my ($table, $row) = map { hex } $reg_key =~ /([0-9A-Fa-f]{2})/g;
    return unless defined $table && defined $row;

    # Write the register value to the thermostat via bus
    $self->write_thermostat($table, $row, $data);

    # Log the notification
    push @{$self->activity_log}, {
        time     => time(),
        action   => 'notify_change',
        register => $reg_key,
    };
}

1;
