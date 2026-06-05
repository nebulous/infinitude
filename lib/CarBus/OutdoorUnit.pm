package CarBus::OutdoorUnit;
use strict;
use warnings;
use feature ':5.10';
use Data::ParseBinary;
use CarBus::Frame;

# OutdoorUnit (ODU) register parsers — read-only monitoring, no emulation.
#
# Register layout observed from Carrier/Bryant heat pump and AC outdoor units
# on the RS485 (ABCD) bus. Data confirmed against thermostat service menu values
# and cross-referenced with InfinitESP passive snoop captures.
#
# Source: https://github.com/nebulous/infinitude/discussions/215

# --- Cycle / runtime counter registers (0310, 0311) ---
#
# Data format: each register is a sequence of 4-byte key-value chunks:
#   Byte 0:   Key (metric identifier, see table below)
#   Bytes 1-3: Value (24-bit big-endian unsigned integer)
#
# ODU key mapping:
#   0x23 = heat_cycles       0x25 = heat_hours
#   0x28 = cool_cycles       0x2A = cool_hours
#   0x3C = defrost_cycles    0x3D = defrost_hours
#   0x2B = poweron_cycles    0x2C = poweron_hours

my %odu_key_names = (
    0x23 => 'heat_cycles',    0x25 => 'heat_hours',
    0x28 => 'cool_cycles',    0x2A => 'cool_hours',
    0x3C => 'defrost_cycles', 0x3D => 'defrost_hours',
    0x2B => 'poweron_cycles', 0x2C => 'poweron_hours',
);

my $ODU_KVEntry = Struct('entry',
    Byte('key'),
    Byte('b1'), Byte('b2'), Byte('b3'),
    Value('value', sub {
        my $c = $_->ctx;
        ($c->{b1} << 16) | ($c->{b2} << 8) | $c->{b3}
    }),
    Value('name', sub {
        my $k = $_->ctx->{key};
        $odu_key_names{$k} // sprintf("unknown_0x%02X", $k)
    }),
);

my $GreedyODUKV = sub {
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
        }, $ODU_KVEntry),
    );
};

# Register 0310 — Cycle counters
#
# Example (4 entries, 16 bytes):
#   23 0000c9 = 201 heat cycles
#   28 0013c7 = 5063 cooling cycles
#   3c 000054 = 84 defrost cycles
#   2b 00002a = 42 power-on cycles
CarBus::Frame->add_device_parser('OutdoorUnit', '0310', $GreedyODUKV->('odu_cycle_counters'));

# Register 0311 — Runtime hours
#
# Example (4 entries, 16 bytes):
#   25 000088 = 136 heating hours
#   2a 002207 = 8711 cooling hours
#   3d 000002 = 2 defrost hours
#   2c 006814 = 26644 power-on hours
CarBus::Frame->add_device_parser('OutdoorUnit', '0311', $GreedyODUKV->('odu_runtime_hours'));

# --- Temperature and status registers (passively snooped) ---

# Register 0302 — Absolute temperatures and thresholds (24 bytes)
#
# 12 int16 BE values: alternating (threshold, measurement), each / 16 = °F.
# Thresholds at even offsets are constants (alarm or control limits);
# measurements at odd offsets are live absolute sensor readings in °F.
# Values are always °F regardless of thermostat F/C display setting.
#
#   Offset  Field               Source
#   0..1    outdoor_threshold    constant
#   2..3    outdoor_temp         OAT sensor (outdoor air temperature)
#   4..5    coil_threshold       constant
#   6..7    coil_temp            outdoor coil temperature
#   8..9    suction_threshold    constant
#   10..11  suction_temp         suction line temperature
#   12..13  liquid_threshold     constant
#   14..15  liquid_temp          liquid line temperature
#   16..17  indoor_coil_thresh   constant
#   18..19  indoor_coil_temp     indoor coil temperature
#   20..21  discharge_threshold  constant
#   22..23  discharge_temp       compressor discharge temperature
#
# Cross-referenced with InfinitESP register 0302 decode_int16_f_ offsets.
CarBus::Frame->add_device_parser('OutdoorUnit', '0302',
    Struct('odu_temperatures',
        SBInt16('outdoor_threshold'),   SBInt16('outdoor_temp'),
        SBInt16('coil_threshold'),      SBInt16('coil_temp'),
        SBInt16('suction_threshold'),   SBInt16('suction_temp'),
        SBInt16('liquid_threshold'),    SBInt16('liquid_temp'),
        SBInt16('indoor_coil_thresh'),  SBInt16('indoor_coil_temp'),
        SBInt16('discharge_threshold'), SBInt16('discharge_temp'),
    )
);

# Register 0303 — Short status (~4 bytes)
#
# Compressor stage encoded in byte 0: stage = data[0] >> 1.
# Remaining bytes are undocumented status flags.
CarBus::Frame->add_device_parser('OutdoorUnit', '0303',
    Struct('odu_short_status',
        Byte('raw_stage'),
        Value('compressor_stage', sub { $_->ctx->{raw_stage} >> 1 }),
        Byte('status1'),
        Byte('status2'),
        Byte('status3'),
    )
);

# Register 0304 — Temperatures, pressures, and operating mode
#
# Operating mode at offset 10. Other fields TBD — register observed at
# 11+ bytes. Prefix fields are temperatures/pressures (exact mapping TBD).
CarBus::Frame->add_device_parser('OutdoorUnit', '0304',
    Struct('odu_status',
        Array(10, Byte('data')),
        Byte('operating_mode'),
    )
);

# Register 0604 — Compressor speed
#
# Pairs of uint16 BE values. First pair = current RPM / target RPM.
# Variable-length register; additional pairs may follow on
# multi-stage or variable-speed systems.
#
# Consumers should read current_rpm and target_rpm directly.
# For additional pairs, parse the raw register data manually.
CarBus::Frame->add_device_parser('OutdoorUnit', '0604',
    Struct('odu_compressor_speed',
        UBInt16('current_rpm'),
        UBInt16('target_rpm'),
    )
);

# Register 0608 — Demand/stage/modulation (7 bytes)
#
#   data[3] = demand (0 or 100 observed)
#   data[5] = stage
#   data[6] = modulation
CarBus::Frame->add_device_parser('OutdoorUnit', '0608',
    Struct('odu_demand',
        Byte('unknown0'),
        Byte('unknown1'),
        Byte('unknown2'),
        Byte('demand'),
        Byte('unknown4'),
        Byte('stage'),
        Byte('modulation'),
    )
);

# Register 060B — Target temperature setpoint
#
# data[4] = target temperature in °F (whole degrees).
# Preceding bytes are mode/zone context.
CarBus::Frame->add_device_parser('OutdoorUnit', '060B',
    Struct('odu_setpoint',
        Byte('unknown0'),
        Byte('unknown1'),
        Byte('unknown2'),
        Byte('unknown3'),
        Byte('setpoint_f'),
    )
);

# Register 061F — IEEE754 float32 array (25 bytes)
#
#   [0]       sub-register (always 0x00)
#   [1..4]    superheat target delta (~7.5°F)
#   [5..8]    superheat actual delta (~10.0°F, drifting)
#   [9..12]   subcooling target delta (~14.0°F)
#   [13..16]  subcooling actual delta (~12.0°F)
#   [17..20]  discharge superheat delta (−68 to +17°F)
#   [21..24]  dimensionless constant (~0.039)
#
# All floats are big-endian IEEE754, °F deltas (not absolute temperatures).
# Confirmed by F/C mode toggle — values do not change with thermostat unit setting.
CarBus::Frame->add_device_parser('OutdoorUnit', '061F',
    Struct('odu_floats',
        Byte('sub_register'),
        BFloat32('superheat_target'),
        BFloat32('superheat_actual'),
        BFloat32('subcooling_target'),
        BFloat32('subcooling_actual'),
        BFloat32('discharge_superheat'),
        BFloat32('unknown_constant'),
    )
);

1;
