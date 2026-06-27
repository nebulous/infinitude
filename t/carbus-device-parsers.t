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
# Helper: parse key-value entries and return { name => value } hash
# ============================================================================
sub parse_kv {
    my ($parser, $data) = @_;
    my $r = $parser->parse($data);
    return {} unless $r && $r->{entry};
    return { map { ($_->{name} // $_->{key}) => $_->{value} } @{$r->{entry}} };
}

# ============================================================================
# ODU: Cycle / runtime counters (named keys)
# ============================================================================

subtest 'OutdoorUnit 0310 cycle counters (named)' => sub {
    my $p = CarBus::Frame::subparser('0310', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0310');
    is($p->{Name}, 'odu_cycle_counters', 'parser name');

    my $data = pack("C*",
        0x23, 0x00, 0x00, 0xC9,
        0x28, 0x00, 0x13, 0xC7,
        0x3C, 0x00, 0x00, 0x54,
        0x2B, 0x00, 0x00, 0x2A,
    );

    my $v = parse_kv($p, $data);
    is($v->{heat_cycles},   201,   'heat cycles');
    is($v->{cool_cycles},   5063,  'cool cycles');
    is($v->{defrost_cycles}, 84,   'defrost cycles');
    is($v->{poweron_cycles}, 42,   'power-on cycles');

    # Verify raw key still present
    my $r = $p->parse($data);
    is($r->{entry}[0]{key}, 0x23, 'raw key byte preserved');
};

subtest 'OutdoorUnit 0311 runtime hours (named)' => sub {
    my $p = CarBus::Frame::subparser('0311', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0311');

    my $data = pack("C*",
        0x25, 0x00, 0x00, 0x88,
        0x2A, 0x00, 0x22, 0x07,
        0x3D, 0x00, 0x00, 0x02,
        0x2C, 0x00, 0x68, 0x14,
    );

    my $v = parse_kv($p, $data);
    is($v->{heat_hours},   136,   'heat hours');
    is($v->{cool_hours},   8711,  'cool hours');
    is($v->{defrost_hours}, 2,    'defrost hours');
    is($v->{poweron_hours}, 26644, 'power-on hours');
};

# ============================================================================
# ODU: Register 0302 — Temperatures (int16 BE / 16 = °F)
# ============================================================================

subtest 'OutdoorUnit 0302 temperatures' => sub {
    my $p = CarBus::Frame::subparser('0302', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0302');
    is($p->{Name}, 'odu_temperatures', 'parser name');

    # Simulate 75.0°F outdoor, 45.5°F coil, 48.25°F suction, 14°F subcooling,
    # 55.75°F indoor ambient, 165.5°F discharge
    # int16 values = °F × 16
    my $data = pack("n*",
        0x04B0, 75.0 * 16,     # outdoor threshold, temp
        0x02B0, 45.5 * 16,     # coil threshold, temp
        0x0300, 48.25 * 16,    # suction threshold, temp
        0x06E0, 14.0 * 16,     # subcooling threshold, value
        0x0380, 55.75 * 16,    # indoor ambient threshold, temp
        0x0A60, 165.5 * 16,    # discharge threshold, temp
    );

    my $r = $p->parse($data);
    ok($r, 'parsed 0302');
    is($r->{outdoor_temp},     1200, 'outdoor temp raw (75.0°F × 16)');
    is($r->{coil_temp},         728, 'coil temp raw (45.5°F × 16)');
    is($r->{suction_temp},      772, 'suction temp raw (48.25°F × 16)');
    is($r->{subcooling_degf_int}, 224, 'subcooling raw (14.0°F × 16)');
    is($r->{indoor_ambient},  892, 'indoor ambient raw (55.75°F × 16)');
    is($r->{discharge_temp},   2648, 'discharge temp raw (165.5°F × 16)');
};

subtest 'OutdoorUnit 0302 negative temperatures' => sub {
    my $p = CarBus::Frame::subparser('0302', 'OutdoorUnit');

    # −10.0°F outdoor temp = -160 as int16 = 0xFF60
    my $data = pack("n*", 0, -160, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    my $r = $p->parse($data);
    is($r->{outdoor_temp}, -160, 'negative outdoor temp raw (−10.0°F × 16)');
};

# ============================================================================
# ODU: Register 0303 — Short status
# ============================================================================

subtest 'OutdoorUnit 0303 short status' => sub {
    my $p = CarBus::Frame::subparser('0303', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0303');
    is($p->{Name}, 'odu_short_status', 'parser name');

    # status0=0x01 (run flag), status1=0x30, suction pressure 114.0 PSIG = 114*16 = 1824
    my $data = pack("C*", 0x01, 0x30, 0x07, 0x20);
    my $r = $p->parse($data);
    is($r->{status0},              1,    'status0 run flag');
    is($r->{status1},              0x30, 'status1 constant');
    is($r->{suction_pressure_psi_x16}, 1824, 'suction pressure raw (114 PSIG x 16)');
    is($r->{suction_pressure_psi},  114,  'suction pressure PSIG (derived)');
};

# ============================================================================
# ODU: Register 0304 — Status with operating mode
# ============================================================================

subtest 'OutdoorUnit 0304 status' => sub {
    my $p = CarBus::Frame::subparser('0304', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0304');
    is($p->{Name}, 'odu_status', 'parser name');

    # byte 7 = line voltage (e.g. 243V)
    my $data = pack("C*", 0,0,0,0,0,0,0, 243, 0,0,0,0,0,0,0,0);
    my $r = $p->parse($data);
    is($r->{line_voltage}, 243, 'line voltage at byte 7');
    is(scalar @{$r->{data}}, 7, '7 prefix data bytes');
    is(scalar @{$r->{tail}}, 8, '8 tail bytes');
};

# ============================================================================
# ODU: Register 0604 — Compressor speed
# ============================================================================

subtest 'OutdoorUnit 0604 compressor speed' => sub {
    my $p = CarBus::Frame::subparser('0604', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0604');
    is($p->{Name}, 'odu_compressor_speed', 'parser name');

    my $data = pack("n*", 3600, 3612);
    my $r = $p->parse($data);
    is($r->{target_rpm},  3600, 'target compressor RPM (round number)');
    is($r->{current_rpm}, 3612, 'current compressor RPM (fluctuating)');
};

# ============================================================================
# ODU: Register 0608 — Demand/stage/modulation
# ============================================================================

subtest 'OutdoorUnit 0608 compressor drive frequency' => sub {
    my $p = CarBus::Frame::subparser('0608', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/0608');
    is($p->{Name}, 'odu_demand', 'parser name');

    # saturation=100 at byte 2; frequency 92.0 Hz = 920 = 0x0398 at bytes 5-6
    my $data = pack("C*", 0x00, 0x00, 100, 0x00, 0x00, 0x03, 0x98);
    my $r = $p->parse($data);
    is($r->{saturation},                100,  'saturation flag (100 when running)');
    is($r->{compressor_frequency_hz_x10}, 920, 'frequency raw (92.0 Hz x 10)');
    is($r->{compressor_frequency_hz},  92,   'frequency Hz (derived)');
};

# ============================================================================
# ODU: Register 060B — Target setpoint
# ============================================================================

subtest 'OutdoorUnit 060B setpoint' => sub {
    my $p = CarBus::Frame::subparser('060B', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/060B');
    is($p->{Name}, 'odu_setpoint', 'parser name');

    my $data = pack("C*", 0x00, 0x00, 0x00, 0x00, 72);
    my $r = $p->parse($data);
    is($r->{setpoint_f}, 72, 'target setpoint 72°F');
};

# ============================================================================
# ODU: Register 061F — IEEE754 floats
# ============================================================================

subtest 'OutdoorUnit 061F floats' => sub {
    my $p = CarBus::Frame::subparser('061F', 'OutdoorUnit');
    ok($p, 'parser found for OutdoorUnit/061F');
    is($p->{Name}, 'odu_floats', 'parser name');

    # Build 25-byte payload with known float values
    # sub_register=0, then 6 × big-endian IEEE754 float32
    my $data = pack("C", 0x00);
    $data .= pack("N", unpack("L", pack("f", 7.5)));    # superheat target
    $data .= pack("N", unpack("L", pack("f", 10.0)));   # superheat actual
    $data .= pack("N", unpack("L", pack("f", 14.0)));   # subcooling target
    $data .= pack("N", unpack("L", pack("f", 12.0)));   # subcooling actual
    $data .= pack("N", unpack("L", pack("f", -5.25)));  # discharge superheat
    $data .= pack("N", unpack("L", pack("f", 0.039)));  # unknown constant

    my $r = $p->parse($data);
    ok($r, 'parsed 061F');
    is($r->{sub_register}, 0, 'sub-register');
    # Float comparison with tolerance
    ok(abs($r->{superheat_target} - 7.5) < 0.01,   'superheat target ~7.5');
    ok(abs($r->{superheat_actual} - 10.0) < 0.01,  'superheat actual ~10.0');
    ok(abs($r->{subcooling_target} - 14.0) < 0.01, 'subcooling target ~14.0');
    ok(abs($r->{subcooling_actual} - 12.0) < 0.01, 'subcooling actual ~12.0');
    ok(abs($r->{discharge_delta} - (-5.25)) < 0.01, 'discharge delta ~-5.25');
    ok(abs($r->{unknown_constant} - 0.039) < 0.001, 'unknown constant ~0.039');
};

# ============================================================================
# IDU: Cycle / runtime counters (named keys)
# ============================================================================

subtest 'IndoorUnit 0310 cycle counters (named)' => sub {
    my $p = CarBus::Frame::subparser('0310', 'IndoorUnit');
    ok($p, 'parser found for IndoorUnit/0310');
    is($p->{Name}, 'idu_cycle_counters', 'parser name');

    my $data = pack("C*",
        0x23, 0x00, 0x1E, 0xEA,
        0x24, 0x00, 0x00, 0x13,
        0x27, 0x00, 0x13, 0xCE,
        0x28, 0x00, 0x00, 0x00,
        0x2B, 0x00, 0x00, 0x85,
        0x2D, 0x00, 0x37, 0xB0,
        0x48, 0x00, 0x00, 0xA0,
    );

    my $v = parse_kv($p, $data);
    is(scalar keys %$v, 7, '7 entries parsed');
    is($v->{low_heat_cycles},  7914,  'low heat cycles');
    is($v->{high_heat_cycles}, 19,    'high heat cycles');
    is($v->{poweron_cycles},   133,   'power-on cycles');
    is($v->{blower_cycles},    14256, 'blower cycles');
    is($v->{med_heat_cycles},  160,   'medium heat cycles');
    is($v->{unknown_0x27},     5070,  'unknown key 0x27');
    is($v->{unknown_0x28},     0,     'unknown key 0x28');
};

subtest 'IndoorUnit 0311 runtime hours (named)' => sub {
    my $p = CarBus::Frame::subparser('0311', 'IndoorUnit');

    my $data = pack("C*",
        0x25, 0x00, 0x07, 0x87,
        0x26, 0x00, 0x00, 0x0A,
        0x29, 0x00, 0x21, 0x91,
        0x2A, 0x00, 0x00, 0x00,
        0x2E, 0x00, 0x65, 0x67,
        0x2C, 0x00, 0x7D, 0xF7,
        0x49, 0x00, 0x00, 0x5B,
    );

    my $v = parse_kv($p, $data);
    is($v->{low_heat_hours},  1927,  'low heat hours');
    is($v->{high_heat_hours}, 10,    'high heat hours');
    is($v->{blower_hours},    25959, 'blower hours');
    is($v->{poweron_hours},   32247, 'power-on hours');
    is($v->{med_heat_hours},  91,    'medium heat hours');
};

# ============================================================================
# IDU: Register 0306 — Blower status
# ============================================================================

subtest 'IndoorUnit 0306 blower status' => sub {
    my $p = CarBus::Frame::subparser('0306', 'IndoorUnit');
    ok($p, 'parser found for IndoorUnit/0306');
    is($p->{Name}, 'idu_status', 'parser name');

    # 10 bytes: status + RPM (uint16 BE) + 7 data bytes
    my $data = pack("C*", 0x01, 0x0E, 0x10, 0, 0, 0, 0, 0, 0, 0);
    my $r = $p->parse($data);
    is($r->{status_flags}, 1, 'status flags');
    is($r->{blower_rpm}, 3600, 'blower RPM decoded from uint16 BE');
    is(scalar @{$r->{data}}, 7, '7 trailing data bytes');
};

# ============================================================================
# IDU: Register 0316 — Airflow config
# ============================================================================

subtest 'IndoorUnit 0316 airflow config' => sub {
    my $p = CarBus::Frame::subparser('0316', 'IndoorUnit');
    ok($p, 'parser found for IndoorUnit/0316');
    is($p->{Name}, 'idu_config', 'parser name');

    # flags=0x03 (electric heat), airflow=1200 CFM, elec_heat=800 CFM, 4 trailing bytes
    my $data = pack("C*", 0x03, 0, 0, 0, 0x04, 0xB0, 0x03, 0x20, 0, 0, 0, 0, 0, 0);
    my $r = $p->parse($data);
    is($r->{electric_heat}, 1,    'electric heat detected');
    is($r->{airflow_cfm},   1200, 'airflow CFM');
    is($r->{elec_heat_cfm}, 800,  'electric heat CFM');
};

subtest 'IndoorUnit 0316 no electric heat' => sub {
    my $p = CarBus::Frame::subparser('0316', 'IndoorUnit');

    my $data = pack("C*", 0x00, 0, 0, 0, 0x03, 0x84, 0, 0, 0, 0, 0, 0, 0, 0);
    my $r = $p->parse($data);
    is($r->{electric_heat}, 0,   'no electric heat');
    is($r->{airflow_cfm},   900, 'airflow CFM');
};

# ============================================================================
# ZC: Cycle / runtime counters (named keys)
# ============================================================================

subtest 'ZoneControl 0310 cycle counters (named)' => sub {
    my $p = CarBus::Frame::subparser('0310', 'ZoneControl');
    ok($p, 'parser found for ZoneControl/0310');
    is($p->{Name}, 'zc_cycle_counters', 'parser name');

    my $data = pack("C*",
        0x38, 0x00, 0x00, 0x01,
        0x39, 0x00, 0x00, 0x01,
        0x2B, 0x00, 0x00, 0x7C,
    );
    my $v = parse_kv($p, $data);
    is($v->{poweron_cycles}, 124, 'power-on cycles named');
    is($v->{unknown_0x38},   1,   'unknown key 0x38 named');
    is($v->{unknown_0x39},   1,   'unknown key 0x39 named');
};

subtest 'ZoneControl 0311 runtime hours (named)' => sub {
    my $p = CarBus::Frame::subparser('0311', 'ZoneControl');

    my $data = pack("C*",
        0x3A, 0x00, 0x00, 0x00,
        0x3B, 0x00, 0x00, 0x00,
        0x2C, 0x00, 0x7E, 0x77,
    );
    my $v = parse_kv($p, $data);
    is($v->{poweron_hours}, 32375, 'power-on hours named');
};

# ============================================================================
# Subparser base-class fallback — OutdoorUnit2 → OutdoorUnit
# ============================================================================

subtest 'subparser base-class fallback' => sub {
    my $p = CarBus::Frame::subparser('0310', 'OutdoorUnit2');
    ok($p, 'OutdoorUnit2 resolves to parser');
    is($p->{Name}, 'odu_cycle_counters', 'OutdoorUnit2 uses OutdoorUnit parser');

    $p = CarBus::Frame::subparser('0311', 'OutdoorUnit2');
    is($p->{Name}, 'odu_runtime_hours', 'OutdoorUnit2 0311 resolves');

    # ODU temperature parser also falls back
    $p = CarBus::Frame::subparser('0302', 'OutdoorUnit2');
    is($p->{Name}, 'odu_temperatures', 'OutdoorUnit2 0302 resolves');

    # IndoorUnit has no numeric suffix — should still work
    $p = CarBus::Frame::subparser('0310', 'IndoorUnit');
    is($p->{Name}, 'idu_cycle_counters', 'IndoorUnit exact match still works');

    # Non-existent device with numeric suffix should not falsely match
    $p = CarBus::Frame::subparser('0310', 'BogusDevice7');
    is($p->{Name}, 'unknown', 'unknown device falls through to global');
};

# ============================================================================
# 24-bit values with nonzero high byte (over 65535)
# ============================================================================

subtest '24-bit values over 65535' => sub {
    my $p = CarBus::Frame::subparser('0311', 'OutdoorUnit');

    my $data = pack("C*",
        0x25, 0x00, 0x00, 0x00,
        0x2A, 0x00, 0x47, 0x0B,
        0x3D, 0x00, 0x00, 0x00,
        0x2C, 0x01, 0x4E, 0x04,
    );

    my $v = parse_kv($p, $data);
    is($v->{poweron_hours}, 85508, '24-bit value with nonzero high byte');
    is($v->{cool_hours},    18187, '16-bit range value still correct');
};

# ============================================================================
# Device-scoped parser isolation — same register, different devices
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

    # Register 0302 is parsed differently by ODU vs ZoneControl
    $odu = CarBus::Frame::subparser('0302', 'OutdoorUnit');
    $zc  = CarBus::Frame::subparser('0302', 'ZoneControl');
    is($odu->{Name}, 'odu_temperatures',  'ODU 0302 = temperatures');
    is($zc->{Name},  'zc_zone_readings',  'ZC 0302 = zone readings');
    isnt($odu->{Name}, $zc->{Name}, '0302 parsers are device-scoped');
};

# ============================================================================
# ODU register 0302 isolation — does not conflict with ZC 0302
# ============================================================================

subtest 'ODU 0302 vs ZC 0302 data isolation' => sub {
    my $odu_p = CarBus::Frame::subparser('0302', 'OutdoorUnit');
    my $zc_p  = CarBus::Frame::subparser('0302', 'ZoneControl');

    # ODU data (24 bytes of int16 pairs)
    my $odu_data = pack("n*", 0, 1200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    my $r = $odu_p->parse($odu_data);
    is($r->{outdoor_temp}, 1200, 'ODU 0302 parses temperature');

    # ZC data (24 bytes TLV format, uint16 temps)
    my $zc_data = pack("C*",
        0x04, 0x01, 0x00, 0x00,
        0x01, 0x02, 0x04, 0x4E,  # zone 2: 0x044E = 1102 / 16 = 68.875°F
        0x01, 0x03, 0x04, 0x4E,
        0x01, 0x04, 0x04, 0x4E,
        0x04, 0x14, 0x00, 0x00,
        0x04, 0x1C, 0x00, 0x00,
    );
    $r = $zc_p->parse($zc_data);
    is($r->{zone2}{value}, 1102, 'ZC 0302 parses zone reading');
};

done_testing();
