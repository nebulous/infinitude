package CarBus::IndoorUnit;
use strict;
use warnings;
use feature ':5.10';
use Data::ParseBinary;
use CarBus::Frame;

# IndoorUnit (IDU) register parsers — read-only monitoring, no emulation.
#
# Register layout observed from Carrier/Bryant furnace/air handler indoor units
# on the RS485 (ABCD) bus. Data confirmed against thermostat service menu values
# and cross-referenced with InfinitESP passive snoop captures.
#
# IDU tables (from device self-described 0xXX01 tabledefs):
#   0x01 DEVCONFG  device configuration (holds device_info at 0104)
#   0x02 SYSTIME  system time/date (thermostat-owned)
#   0x03 RLCSMAIN main controller, RLCS (Residential & Light Commercial Systems) product family - IDU-side sensors/state
#   0x04 VARSPEED variable-speed ECM blower drive (300 bytes, 17 rows)
# Tables 0x05-0x0F return FUNC 0x15 (not present on observed hardware).
#
# Source: https://github.com/nebulous/infinitude/discussions/215

# --- Table 0x03 RLCSMAIN: cycle / runtime counter registers (0310, 0311) ---
#
# Data format: each register is a sequence of 4-byte key-value chunks:
#   Byte 0:   Key (metric identifier, see table below)
#   Bytes 1-3: Value (24-bit big-endian unsigned integer)
#
# IDU key mapping:
#   0x23 = low_heat_cycles    0x25 = low_heat_hours
#   0x24 = high_heat_cycles   0x26 = high_heat_hours
#   0x48 = med_heat_cycles    0x49 = med_heat_hours
#   0x2B = poweron_cycles     0x2C = poweron_hours
#   0x2D = blower_cycles      0x2E = blower_hours

my %idu_key_names = (
    0x23 => 'low_heat_cycles',  0x25 => 'low_heat_hours',
    0x24 => 'high_heat_cycles', 0x26 => 'high_heat_hours',
    0x48 => 'med_heat_cycles',  0x49 => 'med_heat_hours',
    0x2B => 'poweron_cycles',   0x2C => 'poweron_hours',
    0x2D => 'blower_cycles',    0x2E => 'blower_hours',
    0x27 => 'unknown_0x27',     0x29 => 'unknown_0x29',
    0x28 => 'unknown_0x28',     0x2A => 'unknown_0x2A',
);

my $IDU_KVEntry = Struct('entry',
    Byte('key'),
    Byte('b1'), Byte('b2'), Byte('b3'),
    Value('value', sub {
        my $c = $_->ctx;
        ($c->{b1} << 16) | ($c->{b2} << 8) | $c->{b3}
    }),
    Value('name', sub {
        my $k = $_->ctx->{key};
        $idu_key_names{$k} // sprintf("unknown_0x%02X", $k)
    }),
);

my $GreedyIDUKV = sub {
    my ($name) = @_;
    Struct($name,
        Array(sub {
            my $stream = $_->stream;
            return 0 unless $stream && defined ${$stream->{data}};
            my $len = length(${$stream->{data}});
            my $pos = $stream->{offset} // 0;
            my $remaining = $len - $pos;
            return 0 unless $remaining >= 4;
            return int($remaining / 4);
        }, $IDU_KVEntry),
    );
};

# Register 0310 — Cycle counters
#
# Example (7 entries, 28 bytes):
#   23 001eea = 7914 low heat cycles
#   24 000013 = 19 high heat cycles
#   27 0013ce = 5070 unknown
#   28 000000 = 0 unknown
#   2b 000085 = 133 power-on cycles
#   2d 0037b0 = 14256 blower cycles
#   48 0000a0 = 160 medium heat cycles
CarBus::Frame->add_device_parser('IndoorUnit', '0310', $GreedyIDUKV->('idu_cycle_counters'));

# Register 0311 — Runtime hours
#
# Example (7 entries, 28 bytes):
#   25 000787 = 1927 low heat hours
#   26 00000a = 10 high heat hours
#   29 002191 = 8593 unknown
#   2a 000000 = 0 unknown
#   2e 006567 = 25959 blower hours
#   2c 007df7 = 32247 power-on hours
#   49 00005b = 91 medium heat hours
CarBus::Frame->add_device_parser('IndoorUnit', '0311', $GreedyIDUKV->('idu_runtime_hours'));

# --- Status registers (passively snooped) ---

# Register 0306 — Blower / operating status (10 bytes)
#
#   data[0]       = status flags
#   data[1..2]    = blower RPM (uint16 BE)
#   data[3..9]    = undocumented (operating mode, stage, etc.)
#
# Cross-referenced with InfinitESP REG_IDU_STATUS decoding.
CarBus::Frame->add_device_parser('IndoorUnit', '0306',
    Struct('idu_status',
        Byte('status_flags'),
        UBInt16('blower_rpm'),
        Array(7, Byte('data')),
    )
);

# Register 0316 — Airflow configuration (14 bytes)
#
#   data[0] & 0x03 = electric heat present (boolean)
#   data[4..5]     = airflow CFM (uint16 BE)
#   data[6..7]     = electric heat CFM (uint16 BE)
#   Other fields TBD.
#
# Cross-referenced with InfinitESP REG_IDU_CONFIG decoding.
CarBus::Frame->add_device_parser('IndoorUnit', '0316',
    Struct('idu_config',
        Byte('flags'),
        Value('electric_heat', sub { $_->ctx->{flags} & 0x03 ? 1 : 0 }),
        Byte('unknown1'),
        Byte('unknown2'),
        Byte('unknown3'),
        UBInt16('airflow_cfm'),
        UBInt16('elec_heat_cfm'),
        Array(4, Byte('data')),
    )
);

1;
