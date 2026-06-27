package CarBus::SAM;
use Moo;
use Data::ParseBinary;
use CarBus::Frame;
use CarBus::Device;
use Time::HiRes qw(time);

extends 'CarBus::Device';

has '+src_name' => (default => 'FakeSAM');

# Device identity configuration - customize how the emulator identifies itself
# Set clone_mode => 1 to copy real SAM's device info for exact byte-for-byte comparison
has clone_mode => (is => 'ro', default => 0);
has learn_mode => (is => 'ro', default => 0);
has activity_log => (is => 'rw', default => sub { [] });

# Legacy alias — old code and main app use emulated_src
has emulated_src => (is => 'ro', default => 'FakeSAM');

# Custom device identity (used when clone_mode is 0)
# Override these to customize the emulated SAM's identity
has device_identity => (is => 'rw', default => sub {
    {
        device    => 'SYSTEM ACCESS MODULE',
        software  => 'infinitude',
        model     => 'INFINITUDE01',
        serial    => '000000000001000000000001',
        reference => 'SAM00001',
    }
});

# Update device identity (used by clone mode)
sub set_device_identity {
    my ($self, $identity) = @_;
    $self->device_identity($identity);

    # Rebuild register 0104 with new identity
    my $device_info_parser = CarBus::Frame::subparser('0104');
    $self->set_register('0104', $device_info_parser->build($identity));
}

# Override handle_frame to accept both SAM and FakeSAM as dst
# (main app creates SAM with emulated_src => 'SAM' which may differ from src_name)
# A SAM emulator must respond to both its configured src_name and the real SAM address.
around handle_frame => sub {
    my ($orig, $self, $frame) = @_;
    my $fs = $frame->struct;

    return unless defined $fs->{dst};
    return unless $fs->{dst} eq $self->src_name
                || $fs->{dst} eq $self->emulated_src
                || $fs->{dst} eq 'SAM'
                || $fs->{dst} eq 'FakeSAM';

    if ($fs->{cmd} eq 'read') {
        return $self->_handle_read($frame);
    }
    elsif ($fs->{cmd} eq 'write') {
        return $self->_handle_write($frame);
    }
    return;
};

# Override _reply and _exception_reply to use emulated_src when set differently
around _reply => sub {
    my ($orig, $self, $frame, $payload) = @_;
    my $fs = $frame->struct;
    return CarBus::Frame->new(
        src     => $self->emulated_src,
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => $payload,
    );
};

around _exception_reply => sub {
    my ($orig, $self, $frame, $code) = @_;
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
};

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
        metric_units => 'english',
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
        metric_units => 'english',
        change_flags => {
            override_timer => 0, unknown_bit6 => 0, unknown_bit5 => 0,
            system_mode => 0, cool_setpoint => 0, heat_setpoint => 0,
            hold => 0, fan_mode => 0,
        },
        fan_mode => [('auto') x 8],
        zones_holding => {
            z1 => 0, z2 => 0, z3 => 0, z4 => 0,
            z5 => 0, z6 => 0, z7 => 0, z8 => 0,
        },
        heat_setpoint => [(68) x 8],
        cool_setpoint => [(76) x 8],
        humidity_setpoint => [(50) x 8],
        speed_controlled_fan => 0,
        unknown => 0,
        hold_duration => [(0) x 8],
        zone_name => [map { "Zone $_\0" . ("\0" x (12 - length("Zone $_") - 1)) } 1..8],
    }));

    # Register 3B04 - Vacation settings (default: vacation off)
    my $vacation_parser = CarBus::Frame::subparser('3B04');
    $self->set_register('3b04', $vacation_parser->build({
        active => 0,
        metric_units => 'english',
        min_temp => 60,
        max_temp => 85,
        min_humidity => 0,
        max_humidity => 100,
        fan_mode => 'auto',
    }));

    # Register 3B05 - Accessory life and reminders (default: all new/reset)
    my $accessories_parser = CarBus::Frame::subparser('3B05');
    $self->set_register('3b05', $accessories_parser->build({
        active => 0,
        metric_units => 'english',
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
    # NOTE: metric_units defaults to english (0). See the 3B06 parser comment —
    # the unit flag is data[1] (with a mirror at data[10]); the old 'temp_units'
    # field name was a wrong decode (that byte is 0xFF on Touch).
    my $dealer_parser = CarBus::Frame::subparser('3B06');
    $self->set_register('3b06', $dealer_parser->build({
        backlight => 8,
        metric_units => 'english',
        unknown1 => 0,
        deadband => 3,
        cycles_per_hour => 4,
        schedule_periods => 4,
        programs_enabled => 1,
        unknown2 => 0xFF,
        unknown3 => 0xFF,
        programs_enabled_2 => 1,
        metric_units_2 => 'english',
        unknown4 => 0,
        dealer_name => "infinitude\0\0\0\0\0\0\0\0\0\0",
        dealer_phone => "\0" x 20,
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
# 0x3Cxx - Registers the real SAM polls but no device serves (3c0c, 3c0d, 3c14).
#   Observed from physical SAM: 54,076 exception responses in 10.5hr passive capture,
#   3C14 queried 228 times, 3C0C 159 times, 3C0D 151 times during 3-hour run.
#   Always returns exception 0x04 from thermostat. Likely SAM-internal registers
#   that a real SAM would answer to its own reads. Not reimplemented in the emulator
#   — confirmed (2026-04-10) that omitting these polls has no effect on setpoint
#   writes or thermostat behavior.
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
# The SAM may store the value but does not notify the thermostat.

# Register SAM parsers — registered globally via add_parser.
# SAM registers (3Bxx, 030D) don't collide with other devices today.
# Future: migrate to add_device_parser('FakeSAM', ...) if needed.

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
    # data offset 1 = the thermostat's display-unit flag, common to every
    # table-0x3B register. 0=English(°F), 1=Metric(°C). Verified live 2026-06-26:
    # flips within ~1-4s of a CFGEM!M/E set or a thermostat UI unit toggle,
    # consistent across 3 transitions on an Infinity Touch. NOTE: the
    # temperature/humidity/setpoint arrays below are encoded in THIS unit.
    Enum(Byte('metric_units'), english=>0, metric=>1),
    Padding(1),
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
# Contains per-zone setpoints, fan modes, hold status, and names.
# Same 150-byte layout for both read and write.
#
# Bytes 0-2 header (same meaning in both directions):
#   byte 0: active_zones bitmask (read: which zones are active; write: which zones to apply)
#   byte 1: metric_units flag (0=English/°F, 1=Metric/°C) — common to all table-0x3B
#           registers; verified live 2026-06-26. Setpoints below are in THIS unit.
#   byte 2: change_flags bitmask (read: 0x00 = no pending changes;
#           write: which fields changed — 0x01=fan, 0x02=hold, 0x04=heat,
#           0x08=cool, 0x10=mode)
#
# Zone name is 11 chars + NUL = 12 bytes per zone (96 bytes total).
# Touch: AUTO fan means continuous fan OFF; HOLD is "hold permanent"
# Total: 3 + 8 + 1 + 8 + 8 + 8 + 1 + 1 + 16 + 96 = 150 bytes
CarBus::Frame->add_parser('3B03', Struct('sam_zones',
    Byte('active_zones'),
    Enum(Byte('metric_units'), english=>0, metric=>1),
    BitStruct('change_flags',
        Flag('override_timer'),     # 0x80 hold_duration timer set/cancel
        Flag('unknown_bit6'),       # 0x40
        Flag('unknown_bit5'),       # 0x20
        Flag('system_mode'),        # 0x10 mode change (write target: 3B02)
        Flag('cool_setpoint'),      # 0x08 cool_setpoint[8]
        Flag('heat_setpoint'),      # 0x04 heat_setpoint[8]
        Flag('hold'),               # 0x02 zones_holding + hold_duration
        Flag('fan_mode'),           # 0x01 fan_mode[8]
    ),
    Array(8, Enum(Byte('fan_mode'), high=>3, medium=>2, low=>1, auto=>0)),
    BitStruct('zones_holding',           # Touch: "hold permanent" status
        Flag('z8'), Flag('z7'), Flag('z6'), Flag('z5'),
        Flag('z4'), Flag('z3'), Flag('z2'), Flag('z1'),
    ),
    Array(8, Byte('heat_setpoint')),     # Heat setpoint per zone (degrees F)
    Array(8, Byte('cool_setpoint')),     # Cool setpoint per zone (degrees F)
    Array(8, Byte('humidity_setpoint')), # Humidification target per zone (max 99%)
    Byte('speed_controlled_fan'),
    Byte('unknown'),
    Array(8, UBInt16('hold_duration')),  # "Hold until" duration in minutes
    Array(8, Field('zone_name', 12))     # 11 chars max + NUL terminator
));

# 3B04 - Vacation settings register (read-write)
# Max vacation: 365 days (8760 hours)
# Vacation humidity valid values:
#   Legacy: min=0,10,15,20; max=55,60,65,100(NONE)
#   Touch:  min=0(NONE),5,10,15,20,25,30,35,40,45; max=50,55,60,65,100(NONE)
# Layout verified 2026-06-26 from a live read: data[1] is the metric_units flag
# (common to all table-0x3B registers), NOT the high byte of 'hours' as the old
# parser assumed. min_temp/max_temp are at offsets 5/6 (°F or °C per the flag);
# the prior parser read them at 3/4, off by two. The hours field and the zero
# bytes around it need a non-active vacation to fully constrain — left as best
# current decode; vacation was inactive during verification (hours region all 0x00).
CarBus::Frame->add_parser('3B04', Struct('sam_vacation',
    Byte('active'),
    Enum(Byte('metric_units'), english=>0, metric=>1),
    Padding(3),                         # zeros observed; hours live somewhere here
    Byte('min_temp'),                    # Min vacation temperature (F or C per metric_units)
    Byte('max_temp'),                    # Max vacation temperature
    Byte('min_humidity'),                # Min vacation humidity (0 = NONE)
    Byte('max_humidity'),                # Max vacation humidity (100 = NONE)
    Enum(Byte('fan_mode'), high=>3, medium=>2, low=>1, auto=>0 )
));

# 3B05 - Accessory life and reminders register (read-only)
# Contains consumption percentages and reminder flags for accessories
# Values are 0-100% consumption (0 = new/reset, 100 = replace)
# data[1] is the metric_units flag common to all table-0x3B registers (verified
# 2026-06-26); the remaining two header bytes are zeros.
CarBus::Frame->add_parser('3B05', Struct('sam_accessories',
    Byte('active'),
    Enum(Byte('metric_units'), english=>0, metric=>1),
    Padding(1),
    Byte('filter_consumption'),          # Filter life used % (reset with !0)
    Byte('uv_consumption'),              # UV lamp life used % (reset with !0)
    Byte('humidifier_consumption'),      # Humidifier pad life used % (reset with !0)
    Byte('ventilator_consumption'),      # Ventilator filter life used % (reset with !0)
    Enum(Byte('filter_reminders'), off=>0, on=>1),
    Enum(Byte('uv_reminders'), off=>0, on=>1),
    Enum(Byte('humidifier_reminders'), off=>0, on=>1),
    Enum(Byte('ventilator_reminders'), off=>0, on=>1),
));

# 3B06 - Dealer info and configuration register (read-write, 52 bytes)
# Based on infinitive TStatSettings struct (Go: 49 bytes) extended for Touch (52 bytes).
# Touch-specific: CFGAUTO, CFGDEAD, CFGCPH set commands return NAK.
# Touch backlight: ON=level>=3, OFF=level<=2; Set ON->Level8, OFF->Level2.
# dealer_name/dealer_phone: max 18 chars each (Touch: set via online/USB only).
#
# Unit flag CORRECTION (verified live 2026-06-26): the display-unit flag is at
# data[1] (Enum 0=English/°F, 1=Metric/°C), common to all table-0x3B registers,
# with a mirror at data[10]. The prior decode named data[1] 'auto_mode' and
# claimed data[7] was 'temp_units' (F=0x46/C=0x43) — WRONG: data[7] is 0xFF in
# both states on Touch. The F=0x46/C=0x43 ASCII codes appear only on the SAM's
# RS-232 ASCII port (S1CFGEM?), not in this register. ASCII set uses E/M.
CarBus::Frame->add_parser('3B06', Struct('sam_dealer',
    Byte('backlight'),          # 0xFF observed; Touch: ON=level>=3, OFF=level<=2
    Enum(Byte('metric_units'), english=>0, metric=>1),   # display unit flag (data[1])
    Byte('unknown1'),           # Always 0x00
    Byte('deadband'),           # 0-6 (Touch: set returns NAK)
    Byte('cycles_per_hour'),    # 2-6 (Touch: set returns NAK)
    Byte('schedule_periods'),   # 2 or 4 (Touch: set returns NAK)
    Byte('programs_enabled'),   # Touch: set returns NAK
    Byte('unknown2'),           # 0xFF observed (was wrongly labeled 'temp_units')
    Byte('unknown3'),           # 0xFF observed
    Byte('programs_enabled_2'), # 0x01 observed
    Enum(Byte('metric_units_2'), english=>0, metric=>1), # mirror of data[1] flag (data[10])
    Byte('unknown4'),           # 0x00 observed
    Field('dealer_name', 20),   # NUL-padded, max 18 chars (Touch: NAK)
    Field('dealer_phone', 20),  # NUL-padded, max 18 chars (Touch: NAK)
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

# Convenience: read from thermostat (legacy API)
sub read_thermostat {
    my ($self, $table, $row) = @_;
    return $self->read_device('Thermostat', $table, $row);
}

# Convenience: write to thermostat (legacy API)
sub write_thermostat {
    my ($self, $table, $row, $value) = @_;
    return $self->write_device('Thermostat', $table, $row, $value);
}

# Domain method: set heat and cool setpoints for a zone
# Write protocol from infinitive (github.com/acd/infinitive):
#   payload = [00 3B 03] + [00 00 flags] + [zone_data without active_zones prefix]
# The thermostat's read format has 3 extra bytes (active_zones + padding) at the start,
# but the write format uses [00 00 flags] in their place.
# Flags: 0x01=fan, 0x02=hold, 0x04=heat, 0x08=cool, 0x10=mode (3B02)

# Convert integer flag bitmask to change_flags BitStruct hashref
# Bit order matches Data::ParseBinary BitStruct definition (MSB first):
#   bit 7=override_timer, bit 6=unknown_bit6, bit 5=unknown_bit5,
#   bit 4=system_mode, bit 3=cool_setpoint, bit 2=heat_setpoint,
#   bit 1=hold, bit 0=fan_mode
sub _int_to_change_flags {
    my ($self, $flags) = @_;
    return {
        override_timer => ($flags & 0x80) ? 1 : 0,
        unknown_bit6   => ($flags & 0x40) ? 1 : 0,
        unknown_bit5   => ($flags & 0x20) ? 1 : 0,
        system_mode    => ($flags & 0x10) ? 1 : 0,
        cool_setpoint  => ($flags & 0x08) ? 1 : 0,
        heat_setpoint  => ($flags & 0x04) ? 1 : 0,
        hold           => ($flags & 0x02) ? 1 : 0,
        fan_mode       => ($flags & 0x01) ? 1 : 0,
    };
}

# Shared read-modify-write for register 3B03.
# $flags = bitmask of what changed, $mutate = sub { my ($parsed, $idx) = @_; ... }
sub _write_3b03 {
    my ($self, $zone, $flags, $mutate) = @_;
    return unless $flags;

    my $data = $self->get_register('3b03');
    return unless $data && length($data) >= 27;

    my $parser = CarBus::Frame::subparser('3B03');
    my $parsed = $parser->parse($data);

    # Let caller modify parsed fields
    $mutate->($parsed);

    # Set write-mode values for the 3-byte header
    # active_zones is a zero-based zone index (not a bitmask).
    # Real SAM sends zone-1: 0x00, zone-2: 0x01, zone-4: 0x03.
    $parsed->{active_zones} = $zone - 1;
    $parsed->{reserved} = 0;
    $parsed->{change_flags} = $self->_int_to_change_flags($flags);

    my $full_data = $parser->build($parsed);

    # Update our local cache (restore read-format values)
    $parsed->{active_zones} = 0x01;
    $parsed->{change_flags} = $self->_int_to_change_flags(0);
    $self->set_register('3b03', $parser->build($parsed));

    my $payload = pack("C*", 0, 0x3B, 0x03) . $full_data;
    my $frame = CarBus::Frame->new(
        src     => $self->emulated_src,
        src_bus => 1,
        dst     => 'Thermostat',
        dst_bus => 1,
        cmd     => 'write',
        payload_raw => $payload,
    );
    $self->bus->write($frame);

    return 1;
}

sub set_zone_setpoint {
    my ($self, $zone, $heat_sp, $cool_sp) = @_;

    my $flags = 0;
    $flags |= 0x04 if defined $heat_sp;
    $flags |= 0x08 if defined $cool_sp;

    my $idx = $zone - 1;
    return $self->_write_3b03($zone, $flags, sub {
        my ($parsed) = @_;
        $parsed->{heat_setpoint}[$idx] = $heat_sp if defined $heat_sp;
        $parsed->{cool_setpoint}[$idx] = $cool_sp if defined $cool_sp;
    });
}

sub set_zone_fan {
    my ($self, $zone, $fan_mode) = @_;
    return unless defined $fan_mode;

    # Normalize infinitude's "med" to parser's "medium"
    my %fan_map = (med => 'medium');
    $fan_mode = $fan_map{lc($fan_mode)} // lc($fan_mode);

    my $idx = $zone - 1;
    return $self->_write_3b03($zone, 0x01, sub {
        my ($parsed) = @_;
        $parsed->{fan_mode}[$idx] = $fan_mode;
    });
}

# Domain method: set zone hold timer
# Uses flag 0x80 (override active) — the real SAM uses the same 3B03 struct
# with identity data in masked fields and only hold_duration set meaningfully.
# $duration in minutes, 0 to cancel hold
sub set_zone_hold {
    my ($self, $zone, $duration) = @_;
    $duration //= 0;

    my $idx = $zone - 1;
    return $self->_write_3b03($zone, 0x80, sub {
        my ($parsed) = @_;
        $parsed->{hold_duration}[$idx] = $duration;
    });
}

# Domain method: set backlight level
# NOTE: Backlight is a SAM-local setting. The real SAM propagates it via its
# proprietary 3B03 notification blob, which the thermostat doesn't read from us.
# Direct 3B06 writes to the thermostat are silently ignored. This is not currently
# functional — included as a stub for future ASCII protocol integration.
sub set_backlight {
    my ($self, $level) = @_;
    return unless defined $level;

    # Normalize on/off to levels (Touch convention)
    if ($level =~ /^on$/i)    { $level = 8 }
    elsif ($level =~ /^off$/i) { $level = 2 }

    my $parser = CarBus::Frame::subparser('3B06');
    my $data = $self->get_register('3b06');
    return unless defined $data;

    my $parsed = $parser->parse($data);
    $parsed->{backlight} = $level;
    $self->set_register('3b06', $parser->build($parsed));

    return 1;
}

# Domain method: set system mode (heat/cool/auto/off)
# Writes register 3B02 with flag 0x10 in change_flags header
sub set_system_mode {
    my ($self, $mode) = @_;
    return unless defined $mode;
    $mode = lc($mode);

    my $data = $self->get_register('3b02');
    return unless defined $data;

    my $parser = CarBus::Frame::subparser('3B02');
    my $parsed = $parser->parse($data);

    $parsed->{stagmode}{mode} = $mode;
    $parsed->{stagmode}{stage} = 0;

    # Set write-mode header: replace active_zones + padding with flags
    $parsed->{active_zones} = 0;
    # Padding(2) is skipped by parser — we handle it in the raw build

    my $full_data = $parser->build($parsed);

    # Overwrite the 3-byte header with [0x00, 0x00, 0x10] (write-mode flags)
    substr($full_data, 0, 3) = pack("C*", 0, 0, 0x10);

    # Update local cache (restore read-format header)
    my $cache_data = $full_data;
    substr($cache_data, 0, 3) = pack("C*", 0x01, 0, 0);
    $self->set_register('3b02', $cache_data);

    my $payload = pack("C*", 0, 0x3B, 0x02) . $full_data;
    my $frame = CarBus::Frame->new(
        src     => $self->emulated_src,
        src_bus => 1,
        dst     => 'Thermostat',
        dst_bus => 1,
        cmd     => 'write',
        payload_raw => $payload,
    );
    $self->bus->write($frame);

    return 1;
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
