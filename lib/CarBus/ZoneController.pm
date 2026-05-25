package CarBus::ZoneController;
use strict;
use warnings;
use feature ':5.10';
use Moo;
use Data::ParseBinary;
use CarBus::Frame;
use CarBus::Device;

extends 'CarBus::Device';

has '+src_name' => (default => 'ZoneControl');

# Custom device identity
has device_identity => (is => 'rw', default => sub {
    {
        device    => 'INFINITUDE ZONE CTRL',
        location  => '',
        software  => 'INFD-ZC-01',
        model     => 'SYSTXCC4ZC01',
        reference => '000000000000',
        serial    => '',
    }
});

# Static system values from captures (0x14=20, 0x1c=28) — never change
has system_values => (is => 'ro', default => sub { [0x14, 0x1c] });

# Current zone sensor readings (zone 2-4; zone 1 is thermostat direct)
has zone_readings => (is => 'rw', default => sub { [0, 78, 78, 78] });

sub BUILD {
    my $self = shift;
    $self->initialize_defaults();
}

# --- Device-scoped parsers ---
#
# ZC shares register numbers with other devices (0302 is also ODU/IDU, 030d is also
# SAM). Register these with add_device_parser so they only match when the frame's
# source is ZoneControl, leaving other device parsers intact.

# Register 0302 — Zone sensor readings (24 bytes, fixed layout)
#
# Observed from SYSTXCC4ZC01 captures (Feisley, ~4.5 hours, 1181 valid responses):
#
#   Offset  Hex                          Meaning
#   0..3    04 01 00 00                  Header: 4 zones, zone 1 present (no sensor)
#   4..7    01 02 04 XX                  Zone 2: tag=0x01, id=2, reading_tag=0x04, value=XX
#   8..11   01 03 04 YY                  Zone 3: tag=0x01, id=3, reading_tag=0x04, value=YY
#   12..15  01 04 04 ZZ                  Zone 4: tag=0x01, id=4, reading_tag=0x04, value=ZZ
#   16..19  04 14 00 00                  System value 0x14 (20), static
#   20..23  04 1c 00 00                  System value 0x1c (28), static
#
# Tag 0x04 is the ZC reading tag (ODU/IDU use tag 0x02 for sensor readings,
# ODU uses tag 0x05 for status). The reading value is a single byte — possibly
# raw temperature or duct sensor reading depending on sensor placement.
#
# Zone 1 has no entry because it's the main zone controlled directly by the
# thermostat. Only zones 2-4 have remote dampers and duct temperature sensors.
#
# The two system values (0x14, 0x1c) never change across the entire capture set.
# They may be minimum airflow percentages or damper calibration constants.
CarBus::Frame->add_device_parser('ZoneControl', '0302',
    Struct('zc_zone_readings',
        Byte('zone_count'),
        Byte('zone1_present'),
        Padding(2),
        Struct('zone2', Byte('tag'), Byte('id'), Byte('reading_tag'), Byte('value')),
        Struct('zone3', Byte('tag'), Byte('id'), Byte('reading_tag'), Byte('value')),
        Struct('zone4', Byte('tag'), Byte('id'), Byte('reading_tag'), Byte('value')),
        Struct('sysval1', Byte('tag'), Byte('index'), Byte('val_hi'), Byte('val_lo')),
        Struct('sysval2', Byte('tag'), Byte('index'), Byte('val_hi'), Byte('val_lo')),
    )
);

# Register 0319 — Zone config (8 bytes)
#
# Two variants observed (CRC-fail frames, data recovered from most common patterns):
#   Variant 1 (1055x): 00 0a 00 ff ff ff ff ff
#   Variant 2 (53x):   00 00 00 ff ff ff ff ff
#
# The 0xff bytes are unused zone sensor slots. Byte 1 occasionally flips between
# 0x0a and 0x00 — possibly an active sensor count or configuration flag.
CarBus::Frame->add_device_parser('ZoneControl', '0319',
    Struct('zc_zone_config',
        Byte('config_byte1'),
        Byte('config_byte2'),
        Byte('config_byte3'),
        Array(5, Byte('zone_slots')),
    )
);

# Register 030d — Unknown (7 bytes, always zeros)
#
# Shared register number with SAM's "sam_status" (also 7 bytes, different values).
# May be a reserved register, fault log, or feature flag field.
# Polled every ~10 seconds. All captured ZC responses are seven zero bytes.
CarBus::Frame->add_device_parser('ZoneControl', '030d',
    Struct('zc_zeros',
        Array(7, Byte('data')),
    )
);

# Register 3404 — Write/heartbeat flag (1 byte)
#
# The only register the thermostat writes to the ZC. Protocol:
#   1. Thermostat WRITEs 3404=0x00 → ZC ACKs with 0x00
#   2. Thermostat READs 3404 → ZC responds 3404=0x00
#   3. Cycle repeats every ~17 seconds
#
# The value is always 0x00 across the entire capture set.
# Possibly a "config pending" or "heartbeat" flag that the thermostat clears.
CarBus::Frame->add_device_parser('ZoneControl', '3404',
    Struct('zc_heartbeat',
        Byte('flag'),
    )
);

# --- Register initialization ---

sub initialize_defaults {
    my $self = shift;

    return if $self->store->get('registers');

    # Register 0104 - Device info (global parser in Frame.pm)
    my $device_info_parser = CarBus::Frame::subparser('0104');
    $self->set_register('0104', $device_info_parser->build($self->device_identity));

    # Register 0302 - Zone sensor readings
    $self->set_register('0302', $self->_build_0302());

    # Register 0319 - Zone config (8 bytes, from captured data)
    $self->set_register('0319', pack("C*",
        0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    ));

    # Register 030d - Always zeros
    $self->set_register('030d', pack("C*", 0, 0, 0, 0, 0, 0, 0));

    # Register 3404 - Heartbeat flag
    $self->set_register('3404', pack("C", 0x00));
}

# Build register 0302 payload using the device-scoped parser
sub _build_0302 {
    my $self = shift;
    my $z = $self->zone_readings;
    my $sv = $self->system_values;

    my $parser = CarBus::Frame::subparser('0302', 'ZoneControl');
    return $parser->build({
        zone_count    => 4,
        zone1_present => 1,
        zone2 => { tag => 0x01, id => 2, reading_tag => 0x04, value => $z->[1] },
        zone3 => { tag => 0x01, id => 3, reading_tag => 0x04, value => $z->[2] },
        zone4 => { tag => 0x01, id => 4, reading_tag => 0x04, value => $z->[3] },
        sysval1 => { tag => 0x04, index => $sv->[0], val_hi => 0, val_lo => 0 },
        sysval2 => { tag => 0x04, index => $sv->[1], val_hi => 0, val_lo => 0 },
    });
}

# Update zone sensor readings and rebuild register 0302
sub set_zone_reading {
    my ($self, $zone, $value) = @_;
    return unless $zone >= 2 && $zone <= 4;

    my $r = $self->zone_readings;
    $r->[$zone - 1] = $value;
    $self->zone_readings($r);
    $self->set_register('0302', $self->_build_0302());
}

# Handle writes to register 3404 — thermostat clears the flag, we ACK
# with just the value byte (not the full payload like other registers)
around _handle_write => sub {
    my ($orig, $self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));

    my $reply = $self->$orig($frame);

    # For 3404, the ZC ACKs with just the value byte (not the full payload)
    if ($reg_key eq '3404') {
        my $value = substr($fs->{payload_raw}, 3);
        $reply = $self->_reply($frame, $value);
    }

    return $reply;
};

1;
