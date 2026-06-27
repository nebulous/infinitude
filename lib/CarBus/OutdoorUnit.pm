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
# ODU tables (from device self-described 0xXX01 tabledefs):
#   0x01 DEVCONFG  device configuration (holds device_info at 0104)
#   0x02 SYSTIME  system time/date (thermostat-owned; ODU never reads it)
#   0x03 RLCSMAIN main controller, RLCS (Residential & Light Commercial Systems) product family - sensors & loop state
#   0x06 VAR COMP variable-speed compressor drive - frequency & stage
# Tables 0x04,0x05,0x07-0x0F return FUNC 0x15 (not present on observed hardware).
#
# Source: https://github.com/nebulous/infinitude/discussions/215

# --- Table 0x03 RLCSMAIN: cycle / runtime counter registers (0310, 0311) ---
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

# --- Table 0x03 RLCSMAIN: temperature and status registers (passively snooped) ---

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
#   14..15  subcooling_degf_int  subcooling ΔT (integer °F, not absolute temperature)
#   16..17  indoor_amb_thresh    constant
#   18..19  indoor_ambient       indoor ambient (likely echoed from broadcast 3B02; not a coil thermistor)
#   20..21  discharge_threshold  constant
#   22..23  discharge_temp       compressor discharge temperature
#
# Previously labeled indoor_coil_temp; matches zone ambient during active
# cooling (a real evaporator would read ~40F), so this system has no coil
# thermistor on the bus. Cross-referenced with InfinitESP 0302 decoding.
CarBus::Frame->add_device_parser('OutdoorUnit', '0302',
    Struct('odu_temperatures',
        SBInt16('outdoor_threshold'),   SBInt16('outdoor_temp'),
        SBInt16('coil_threshold'),      SBInt16('coil_temp'),
        SBInt16('suction_threshold'),   SBInt16('suction_temp'),
        SBInt16('liquid_threshold'),    SBInt16('subcooling_degf_int'),
        SBInt16('indoor_amb_thresh'),   SBInt16('indoor_ambient'),
        SBInt16('discharge_threshold'), SBInt16('discharge_temp'),
    )
);

# Register 0303 — Short status (4 bytes)
#
#   data[0]    = status byte (constant 0x01 — run flag, not a stage index).
#                The variable-speed stage is on 060e byte 0, not here.
#   data[1]    = status byte (constant 0x30).
#   data[2..3] = suction line pressure, uint16 BE, PSI×16 (÷16 = PSIG).
#                Same fractional encoding as the temperature registers
#                (byte 3 is always a multiple of 16 → 1 PSIG resolution).
#                Real transducer — reads ~104-130 PSIG while cooling and
#                ~190-210 PSIG when off (equalized standing pressure).
#                Confirmed against thermostat odu_status.suctpress: exact
#                match at tight-timing samples, and r=0.95 vs R-410A
#                saturation pressure computed from bus temperatures across
#                ~27k frames. The transducer reads systematically higher
#                than the evap-saturation estimate because it sees actual
#                suction-line pressure (includes the superheat region).
CarBus::Frame->add_device_parser('OutdoorUnit', '0303',
    Struct('odu_short_status',
        Byte('status0'),
        Byte('status1'),
        UBInt16('suction_pressure_psi_x16'),
        Value('suction_pressure_psi', sub { $_->ctx->{suction_pressure_psi_x16} / 16 }),
    )
);

# Register 0304 — Status (16 bytes), 0x03 RLCSMAIN.
#
#   data[7] = line voltage (whole volts; e.g. 239/248). Confirmed against
#             thermostat odu_status.linevolt.
#   The operating MODE (odu_status.opmode) is NOT in this register — byte 10
#   is 0 in every observed frame (cooling and off). opmode's bus source is
#             undetermined; see notes on opstat/opmode below. Other fields TBD.
CarBus::Frame->add_device_parser('OutdoorUnit', '0304',
    Struct('odu_status',
        Array(7, Byte('data')),
        Byte('line_voltage'),
        Array(8, Byte('tail')),
    )
);

# --- Table 0x06 VAR COMP: compressor drive registers ---

# Register 0604 — Compressor speed
#
# Pairs of uint16 BE values: (target_rpm, actual_rpm) per operating stage.
# Target is the round commanded value; actual fluctuates around it.
# Variable-length register — first pair is the primary compressor.
# Additional pairs may follow on multi-stage or variable-speed systems.
CarBus::Frame->add_device_parser('OutdoorUnit', '0604',
    Struct('odu_compressor_speed',
        UBInt16('target_rpm'),
        UBInt16('current_rpm'),
    )
);

# Register 0608 — Compressor drive frequency (7 bytes)
#
#   data[5..6] = compressor drive frequency, uint16 BE, 0.1 Hz.
#                Fits Carrier rated stage RPMs within 1% for stages 1-4
#                on a 4-pole motor (sync rpm = 3*v); stage 5 (144 Hz)
#                predicted, not yet measured.
#   data[2]    = saturation flag (0 when off, 100 when running; even at
#                low stage, so not a load %). Offsets 0,1,3,4 are 0 here.
#
# Note: data[5] alone (the high byte) looks like a stage index but is
# floor(v/256) and collides: stages 2 and 3 both fall in data[5]=3.
# Use register 060e byte 0 for the stage index.
CarBus::Frame->add_device_parser('OutdoorUnit', '0608',
    Struct('odu_demand',
        Byte('unknown0'),
        Byte('unknown1'),
        Byte('saturation'),
        Byte('unknown3'),
        Byte('unknown4'),
        UBInt16('compressor_frequency_hz_x10'),
        Value('compressor_frequency_hz', sub { $_->ctx->{compressor_frequency_hz_x10} / 10 }),
    )
);

# Register 0605 — Commanded compressor stage (4 bytes, write-only)
#
# float32 BE at [0..3]: 0.0 = off, 1.0..5.0 = commanded stage. Write-only
# (thermostat→ODU); the ODU never replies to this register, so it only
# appears in passive write captures, not poll replies. Drives the actual
# stage reported on 060e with a ~15s lag.
CarBus::Frame->add_device_parser('OutdoorUnit', '0605',
    Struct('odu_commanded_stage',
        BFloat32('commanded_stage'),
    )
);

# Register 060E — Variable-speed stage info (125 bytes)
#
# byte 0 = stage index: {0=off, 1..5=stage}. Contiguous integers,
# monotonic with compressor output. Verified against rpm-derived stage
# (nearest of 1500/2460/2800/3650/4320) across ~16k frames. The one
# ambiguity frequency cannot resolve (1500 and 1700 rpm both run at
# ~52 Hz) is labeled correctly here as stage 1.
# Remaining 124 bytes undecoded.
CarBus::Frame->add_device_parser('OutdoorUnit', '060E',
    Struct('odu_stage_info',
        Byte('stage'),
        Array(124, Byte('data')),
    )
);

# Register 060B — Variable target value (write-only, thermostat→ODU)
#
# data[2] = target value, native °F whole degrees. Offset fix: was data[4]
#           (always 0); data[2] carries the value (verified in InfinitESP).
#           Range 25-115°F, varies independently of OAT and zone setpoints.
#           NOT confirmed to be a cooling setpoint — the thermostat does not
#           tell the ODU an indoor setpoint; likely a refrigerant-loop
#           coil/discharge control target. Label kept pending further decode.
CarBus::Frame->add_device_parser('OutdoorUnit', '060B',
    Struct('odu_setpoint',
        Byte('unknown0'),
        Byte('unknown1'),
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
#   [17..20]  discharge-related delta (see below) — NOT literal discharge superheat.
#             0.000 when the compressor is off; live only while running, where it
#             runs ~−68 to +15 (mean ~−14, ~75% of samples negative). Tracks
#             discharge_temp (r≈0.91), compressor rpm/stage (r≈0.91/0.87), and is
#             monotonic per stage (stage1 ≈ −27, stage2 ≈ −1, stage3 ≈ +7, stage4 ≈
#             +12). It is NOT a linear combination of the bus-visible temperatures
#             (best R²≈0.92 using discharge+coil+oat), so it incorporates an input
#             not exposed on the bus — most likely head/discharge pressure (condensing
#             temperature from an internal transducer, like suctpress). Literal
#             discharge superheat (discharge_temp − condensing_temp) is always
#             positive, so the former 'discharge_superheat' label is wrong; the
#             quantity is most likely a discharge-temperature/superheat control
#             deviation reported by the variable-compressor loop. Exact identity
#             unconfirmed without the head-pressure register.
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
        BFloat32('discharge_delta'),
        BFloat32('unknown_constant'),
    )
);

1;
