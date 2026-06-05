package CarBus::IndoorUnit;
use strict;
use warnings;
use feature ':5.10';
use Data::ParseBinary;
use CarBus::Frame;

# IndoorUnit (IDU) register parsers — read-only monitoring, no emulation.
#
# Register layout observed from Carrier/Bryant furnace/air handler indoor units
# on the RS485 (ABCD) bus. Data confirmed against thermostat service menu values.
#
# Data format: each register is a sequence of 4-byte key-value chunks:
#   Byte 0:   Key (metric identifier, see table below)
#   Bytes 1-3: Value (24-bit big-endian unsigned integer)
#
# Known keys for IndoorUnit:
#   0x23 = Low heat cycles      0x25 = Low heat hours
#   0x24 = High heat cycles     0x26 = High heat hours
#   0x48 = Medium heat cycles   0x49 = Medium heat hours
#   0x2B = Power-on cycles      0x2C = Power-on hours
#   0x2D = Blower cycles        0x2E = Blower hours
#   0x27 = Unknown (matches cool count?)   0x29 = Unknown (matches cool hours?)
#   0x28 = Unknown (0 on observed system)
#
# Source: https://github.com/nebulous/infinitude/discussions/215

# Reusable 4-byte key-value entry: 1-byte key + 3-byte big-endian value
my $KVEntry = Struct('entry',
    Byte('key'),
    Byte('b1'), Byte('b2'), Byte('b3'),
    Value('value', sub {
        my $c = $_->ctx;
        ($c->{b1} << 16) | ($c->{b2} << 8) | $c->{b3}
    }),
);

# Greedy array — reads until stream is exhausted, 4 bytes at a time
my $GreedyKV = sub {
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
        }, $KVEntry),
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
CarBus::Frame->add_device_parser('IndoorUnit', '0310', $GreedyKV->('idu_cycle_counters'));

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
CarBus::Frame->add_device_parser('IndoorUnit', '0311', $GreedyKV->('idu_runtime_hours'));

1;
