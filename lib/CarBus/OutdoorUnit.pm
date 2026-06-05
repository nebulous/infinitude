package CarBus::OutdoorUnit;
use strict;
use warnings;
use feature ':5.10';
use Data::ParseBinary;
use CarBus::Frame;

# OutdoorUnit (ODU) register parsers — read-only monitoring, no emulation.
#
# Register layout observed from Carrier/Bryant heat pump and AC outdoor units
# on the RS485 (ABCD) bus. Data confirmed against thermostat service menu values.
#
# Data format: each register is a sequence of 4-byte key-value chunks:
#   Byte 0:   Key (metric identifier, see table below)
#   Bytes 1-3: Value (24-bit big-endian unsigned integer)
#
# Known keys for OutdoorUnit:
#   0x23 = Heat cycles        0x25 = Heat hours
#   0x28 = Cool cycles        0x2A = Cool hours
#   0x3C = Defrost cycles     0x3D = Defrost hours
#   0x2B = Power-on cycles    0x2C = Power-on hours
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
# Example (4 entries, 16 bytes):
#   23 0000c9 = 201 heat cycles
#   28 0013c7 = 5063 cooling cycles
#   3c 000054 = 84 defrost cycles
#   2b 00002a = 42 power-on cycles
CarBus::Frame->add_device_parser('OutdoorUnit', '0310', $GreedyKV->('odu_cycle_counters'));

# Register 0311 — Runtime hours
#
# Example (4 entries, 16 bytes):
#   25 000088 = 136 heating hours
#   2a 002207 = 8711 cooling hours
#   3d 000002 = 2 defrost hours
#   2c 006814 = 26644 power-on hours
CarBus::Frame->add_device_parser('OutdoorUnit', '0311', $GreedyKV->('odu_runtime_hours'));

1;
