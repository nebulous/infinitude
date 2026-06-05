#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use CarBus::Frame;
use CarBus::OutdoorUnit;
use CarBus::IndoorUnit;
use CarBus::ZoneController;

# ============================================================================
# Helper: parse key-value entries and return { key_hex => value } hash
# ============================================================================
sub parse_kv {
    my ($parser, $data) = @_;
    my $r = $parser->parse($data);
    return {} unless $r && $r->{entry};
    return { map { sprintf("0x%02X", $_->{key}) => $_->{value} } @{$r->{entry}} };
}

# ============================================================================
# Test 1: OutdoorUnit 0310 — cycle counters (discussion #215 example data)
# ============================================================================
subtest 'OutdoorUnit 0310 cycle counters' => sub {
    my $p = CarBus::Frame::subparser('0310', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0310');
    is($p->{Name}, 'odu_cycle_counters', 'parser name');

    # Raw data from discussion #215:
    # 23 0000c9 = 201 heat, 28 0013c7 = 5063 cool,
    # 3c 000054 = 84 defrost, 2b 00002a = 42 power-on
    my $data = pack("C*",
        0x23, 0x00, 0x00, 0xC9,
        0x28, 0x00, 0x13, 0xC7,
        0x3C, 0x00, 0x00, 0x54,
        0x2B, 0x00, 0x00, 0x2A,
    );

    my $v = parse_kv($p, $data);
    is($v->{'0x23'}, 201,   'heat cycles');
    is($v->{'0x28'}, 5063,  'cool cycles');
    is($v->{'0x3C'}, 84,    'defrost cycles');
    is($v->{'0x2B'}, 42,    'power-on cycles');
};

# ============================================================================
# Test 2: OutdoorUnit 0311 — runtime hours (discussion #215 example data)
# ============================================================================
subtest 'OutdoorUnit 0311 runtime hours' => sub {
    my $p = CarBus::Frame::subparser('0311', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0311');
    is($p->{Name}, 'odu_runtime_hours', 'parser name');

    # 25 000088 = 136 heat, 2a 002207 = 8711 cool,
    # 3d 000002 = 2 defrost, 2c 006814 = 26644 power-on
    my $data = pack("C*",
        0x25, 0x00, 0x00, 0x88,
        0x2A, 0x00, 0x22, 0x07,
        0x3D, 0x00, 0x00, 0x02,
        0x2C, 0x00, 0x68, 0x14,
    );

    my $v = parse_kv($p, $data);
    is($v->{'0x25'}, 136,   'heat hours');
    is($v->{'0x2A'}, 8711,  'cool hours');
    is($v->{'0x3D'}, 2,     'defrost hours');
    is($v->{'0x2C'}, 26644, 'power-on hours');
};

# ============================================================================
# Test 3: IndoorUnit 0310 — cycle counters (discussion #215 example data)
# ============================================================================
subtest 'IndoorUnit 0310 cycle counters' => sub {
    my $p = CarBus::Frame::subparser('0310', 'IndoorUnit');
    ok($p, 'parser found for IndoorUnit/0310');
    is($p->{Name}, 'idu_cycle_counters', 'parser name');

    my $data = pack("C*",
        0x23, 0x00, 0x1E, 0xEA,   # 7914 low heat
        0x24, 0x00, 0x00, 0x13,   # 19 high heat
        0x27, 0x00, 0x13, 0xCE,   # 5070 unknown
        0x28, 0x00, 0x00, 0x00,   # 0
        0x2B, 0x00, 0x00, 0x85,   # 133 power-on
        0x2D, 0x00, 0x37, 0xB0,   # 14256 blower
        0x48, 0x00, 0x00, 0xA0,   # 160 medium heat
    );

    my $v = parse_kv($p, $data);
    is(scalar keys %$v, 7, '7 entries parsed');
    is($v->{'0x23'}, 7914,  'low heat cycles');
    is($v->{'0x24'}, 19,    'high heat cycles');
    is($v->{'0x2B'}, 133,   'power-on cycles');
    is($v->{'0x2D'}, 14256, 'blower cycles');
    is($v->{'0x48'}, 160,   'medium heat cycles');
};

# ============================================================================
# Test 4: IndoorUnit 0311 — runtime hours (discussion #215 example data)
# ============================================================================
subtest 'IndoorUnit 0311 runtime hours' => sub {
    my $p = CarBus::Frame::subparser('0311', 'IndoorUnit');
    ok($p, 'parser found for IndoorUnit/0311');

    my $data = pack("C*",
        0x25, 0x00, 0x07, 0x87,   # 1927 low heat
        0x26, 0x00, 0x00, 0x0A,   # 10 high heat
        0x29, 0x00, 0x21, 0x91,   # 8593
        0x2A, 0x00, 0x00, 0x00,   # 0
        0x2E, 0x00, 0x65, 0x67,   # 25959 blower
        0x2C, 0x00, 0x7D, 0xF7,   # 32247 power-on
        0x49, 0x00, 0x00, 0x5B,   # 91 medium heat
    );

    my $v = parse_kv($p, $data);
    is($v->{'0x25'}, 1927,  'low heat hours');
    is($v->{'0x26'}, 10,    'high heat hours');
    is($v->{'0x2E'}, 25959, 'blower hours');
    is($v->{'0x2C'}, 32247, 'power-on hours');
    is($v->{'0x49'}, 91,    'medium heat hours');
};

# ============================================================================
# Test 5: ZoneControl 0310/0311 (discussion #215 example data)
# ============================================================================
subtest 'ZoneControl 0310 cycle counters' => sub {
    my $p = CarBus::Frame::subparser('0310', 'ZoneControl');
    ok($p, 'parser found for ZoneControl/0310');
    is($p->{Name}, 'zc_cycle_counters', 'parser name');

    my $data = pack("C*",
        0x38, 0x00, 0x00, 0x01,
        0x39, 0x00, 0x00, 0x01,
        0x2B, 0x00, 0x00, 0x7C,
    );
    my $v = parse_kv($p, $data);
    is($v->{'0x2B'}, 124, 'power-on cycles');
};

subtest 'ZoneControl 0311 runtime hours' => sub {
    my $p = CarBus::Frame::subparser('0311', 'ZoneControl');
    ok($p, 'parser found for ZoneControl/0311');

    my $data = pack("C*",
        0x3A, 0x00, 0x00, 0x00,
        0x3B, 0x00, 0x00, 0x00,
        0x2C, 0x00, 0x7E, 0x77,
    );
    my $v = parse_kv($p, $data);
    is($v->{'0x2C'}, 32375, 'power-on hours');
};

# ============================================================================
# Test 6: subparser base-class fallback — OutdoorUnit2 → OutdoorUnit
# ============================================================================
subtest 'subparser base-class fallback' => sub {
    # OutdoorUnit2 should fall back to OutdoorUnit parsers
    my $p = CarBus::Frame::subparser('0310', 'OutdoorUnit2');
    ok($p, 'OutdoorUnit2 resolves to parser');
    is($p->{Name}, 'odu_cycle_counters', 'OutdoorUnit2 uses OutdoorUnit parser');

    $p = CarBus::Frame::subparser('0311', 'OutdoorUnit2');
    is($p->{Name}, 'odu_runtime_hours', 'OutdoorUnit2 0311 resolves');

    # IndoorUnit has no numeric suffix — should still work
    $p = CarBus::Frame::subparser('0310', 'IndoorUnit');
    is($p->{Name}, 'idu_cycle_counters', 'IndoorUnit exact match still works');

    # Non-existent device with numeric suffix should not falsely match
    $p = CarBus::Frame::subparser('0310', 'BogusDevice7');
    is($p->{Name}, 'unknown', 'unknown device falls through to global');
};

# ============================================================================
# Test 7: 24-bit values with nonzero high byte (over 65535)
# ============================================================================
subtest '24-bit values over 65535' => sub {
    my $p = CarBus::Frame::subparser('0311', 'OutdoorUnit');

    # power-on hours = 85508 = 0x014E04 — byte 1 is nonzero
    my $data = pack("C*",
        0x25, 0x00, 0x00, 0x00,   # 0 heat hours
        0x2A, 0x00, 0x47, 0x0B,   # 18187 cool hours
        0x3D, 0x00, 0x00, 0x00,   # 0 defrost hours
        0x2C, 0x01, 0x4E, 0x04,   # 85508 power-on hours (nonzero byte 1)
    );

    my $v = parse_kv($p, $data);
    is($v->{'0x2C'}, 85508, '24-bit value with nonzero high byte');
    is($v->{'0x2A'}, 18187, '16-bit range value still correct');
};

# ============================================================================
# Test 8: Device-scoped parser isolation — same register, different devices
# ============================================================================
subtest 'device parser isolation' => sub {
    my $odu = CarBus::Frame::subparser('0310', 'OutdoorUnit');
    my $idu = CarBus::Frame::subparser('0310', 'IndoorUnit');
    my $zc  = CarBus::Frame::subparser('0310', 'ZoneControl');

    is($odu->{Name}, 'odu_cycle_counters',  'ODU parser name');
    is($idu->{Name}, 'idu_cycle_counters',  'IDU parser name');
    is($zc->{Name},  'zc_cycle_counters',   'ZC parser name');

    isnt($odu->{Name}, $idu->{Name}, 'ODU and IDU parsers are distinct');
    isnt($odu->{Name}, $zc->{Name},  'ODU and ZC parsers are distinct');
};

done_testing();
