package CarBus::Frame;
use Moo;
use Data::ParseBinary;
use Digest::CRC 'crc16';
use Try::Tiny;

my %device_classes = (
	SystemInit => 0x1F,    # Thermostat re-addressed from 0x20 during bus discovery — perhaps
	                       # to avoid reflected messages, prevent loops, or detect other
	                       # thermostats already occupying 0x20/0x21/…
	SAM => 0x92,
	FakeSAM => 0x93,
	Broadcast => 0xF1,
	_default_ => $DefaultPass
);

my $classmap = {
    2 => 'Thermostat',
    3 => 'Sensor',
    4 => 'IndoorUnit',
    5 => 'OutdoorUnit',
    6 => 'ZoneControl',
    8 => 'NIM',
    #9 => 'SAM'
};

foreach my $pre (keys %$classmap) {
    my $label = $classmap->{$pre};
    my $idx=0;
    while($idx<0xF) {
        my $addr = ($pre<<4) + $idx;
        $device_classes{$label.($idx ? $idx : '')} ||= $addr;
        $idx++;
    }
}

my $fp = Struct("CarFrame",
  Enum(Byte("dst"),%device_classes), Byte("dst_bus"),
  Enum(Byte("src"),%device_classes), Byte("src_bus"),
  Byte("length"),
  Byte('pid'),
  Byte('ext'),
  Enum(Byte("cmd"),
      reply => 0x06,
      read => 0x0B,
      write => 0x0C,
      exception => 0x15,
      _default_ => $DefaultPass
  ),
  Field("payload_raw", sub { $_->ctx->{length} }),
  ULInt16("checksum"),

  Value("raw", sub { ${$_->stream->{data}}; }),
  Value("as_hex", sub { unpack("H*",$_->ctx->{raw}) }),
  Value("reg_string", sub { length($_->ctx->{payload_raw})>=3 ? substr($_->ctx->{as_hex}, 18,4) : undef}),
  Value("gensum", sub { crc16(substr($_->ctx->{raw},0,-2)) }),
  Value("valid", sub { $_->ctx->{gensum} == $_->ctx->{checksum} ? 1 : 0 }),
  Value("payload", sub {
      return undef unless $_->ctx->{valid};
      return undef if length($_->ctx->{payload_raw})<=3;
      my $sp = subparser($_->ctx->{reg_string}, $_->ctx->{src});
      try { $sp->parse(substr($_->ctx->{payload_raw},3)) } || undef;
  }),
  Value("payload_hex", sub { unpack("H*", $_->ctx->{payload_raw}) }),

  Value("reg_name", sub {
    my $fh = $_->ctx;
    my $subp = subparser($fh->{reg_string}, $fh->{src});
    my $regname = $fh->{reg_string} // '';
    $regname = $subp->{Name}."($regname)" if $subp;
    return $regname;
  })
);

around BUILDARGS => sub {
    my ( $orig, $class, @args ) = @_;
    (@args) = %{$args[0]}
      if @args == 1 && ref $args[0] eq 'HASH';

    my $init_frame = chr(0)x10;
    $init_frame = shift @args if (@args == 1 && !ref $args[0]);
    $init_frame = pack("H*", $init_frame) if $init_frame =~ /^[0-9A-Fa-f]+$/;
    my $struct = { valid=>0 };
    try {
        $struct = $fp->parse($init_frame);
        $struct = {%$struct,@args};
    };

    return $class->$orig({struct=>$struct});
};

has struct => (is=>'rw');

sub valid { shift->struct->{valid} }

sub frame {
    my $self = shift;
    my $changes = shift // {};
    return undef unless $self->struct->{valid} or keys %$changes;

    foreach my $change (keys %$changes) {
        $self->struct->{$change} = $changes->{$change};
    }

    my $struct = $self->struct;
    $struct->{length} = length($struct->{payload_raw});
    $struct = $fp->parse($fp->build($struct));

    if ($struct->{checksum} != $struct->{gensum}) {
        $struct->{checksum} = $struct->{gensum};
        $struct = $fp->parse($fp->build($struct));
    }
    $self->struct($struct);

    return $self->struct->{valid} ? $self->struct->{raw} : undef;
}

sub frame_hex {
    my $self = shift;
    $self->frame;
    return $self->struct->{as_hex};
}

sub frame_hash {
    my $self = shift;
    $self->frame;
    return $self->struct;
}

sub frame_log {
    my $self = shift;
    my $fh = $self->frame_hash;
    return join(' ',
        $fh->{src},
        $fh->{cmd},
        $fh->{dst},
        $fh->{reg_name},
        $fh->{valid}
    );
}

my @schedchunk = (
    Byte('min15s'), Enum(Byte('mode'), home=>0, away=>1, sleep=>2, wake=>3),
    Value('enabled', sub { $_->ctx->{min15s} == 0x60 ? 0 : 1 }),
    Value("time", sub { sprintf("%02d:%02d", int($_->ctx->{min15s}/4), 15*int($_->ctx->{min15s}%4)) }),
    );

our $parsers = {
    # Table-definition register (every table's 0xNN01). Describes the table's
    # name, total NVRAM allocation, row count, and one (size, access) pair per
    # register address slot. Verified across the thermostat, IDU, and ODU by
    # probing live devices and cross-referencing the bus-logger capture:
    #
    #   [0]      0x00
    #   [1]      small flags/counter byte (0x20/0x21/0x30/0x31 observed); NOT
    #            an ASCII revision — semantics undetermined.
    #   [2..9]   8-char table name, NUL/space-padded
    #            (DEVCONFG, SYSTIME, RLCSMAIN, VARSPEED, VAR COMP, LINESET, ...)
    #   [10..11] total table allocation (u16 BE) = self_size + Σ(every slot's
    #            size byte). Gaps count as 222 (0xDE); empty slots as 0.
    #   [12]     rows = total address-slot count, INCLUDING this 0xNN01 register.
    #            So the number of (size,access) pairs below is rows-1.
    #   [13]     self_size = byte length of THIS tabledef register.
    #   [14]     0x01 = descriptor-list flag.
    #   [15..]   one (size, access) pair per slot, addresses running NN02, NN03, ...
    #            (0xDE, 0xDE) = absent slot (returns exception if read)
    #            (0x00, 0x00) = empty slot
    #
    # access is a 2-bit permission flag, proven at register level on the live bus:
    #   bit0 = readable, bit1 = writable.
    #   0x01 read-only   — readable; never written in 1.4M captured frames.
    #   0x02 write-only  — write is acked; READ RETURNS AN EXCEPTION (proven on
    #                      thermostat register 3131). Table-level only on the
    #                      IDU/ODU (SYSTIME), but present at register level on
    #                      the thermostat (INGDATA 0x31).
    #   0x03 read/write  — write is acked (proven on ODU 0610), also readable.
    '01' => Struct('tabledef',
        Byte('zero'),
        Byte('flags'),
        String('name', 8),
        UBInt16('total_allocation'),
        Byte('rows'),
        Byte('self_size'),
        Byte('descriptor_flag'),
        Array(sub { ($_->ctx->{rows}) - 1 },
            Struct("rowdef",
                Byte("size"),
                Enum(Byte("access"), 'read'=>1, 'write'=>2,'read/write'=>3, _default_ => $DefaultPass)
            )
        )
    ),

    '0104' => Struct('device_info',
        PaddedString('device', 24, paddir=>'right'),
        PaddedString('location', 24, paddir=>'right'),
        PaddedString('software', 16, paddir=>'right'),
        PaddedString('model', 20, paddir=>'right'),
        PaddedString('reference', 12, paddir=>'right'),
        PaddedString('serial', 24, paddir=>'right'),
    ),

    '0202' => Struct('time', Byte('hour'), Byte('minute'), Enum(Byte('weekday'), Sunday=>0, Monday=>1, Tuesday=>2, Wednesday=>3, Thursday=>4, Friday=>5, Saturday=>6)),

    '0203' => Struct('date', Byte('day'), Byte('month'), Byte('20xx'), Value('year', sub { 2000+int($_->ctx->{'20xx'}) })),

    # zone 1
    '4002' => Struct('schedule',
        Array(7, Array(5, Struct('chunk',@schedchunk)))
    ),
    # zone 1
    # Comfort profiles: 5 activities × 7 bytes each
    # Byte 3: (rhtg << 4) | rclg — dehumidify reheat heating/cooling setpoint indices
    # Byte 4: humidifier/ventilation mode flags (bitfield, exact mapping TBD)
    # Bytes 5-6: unknown (always 0x1E on observed system)
    '400A' => Struct('comfort_profile',
        Struct('home', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3),
            BitStruct('dehumidify', Nibble('rhtg'), Nibble('rclg')),
            Byte('hum_vent_flags'), Array(2, Byte('unknown'))),
        Struct('away', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3),
            BitStruct('dehumidify', Nibble('rhtg'), Nibble('rclg')),
            Byte('hum_vent_flags'), Array(2, Byte('unknown'))),
        Struct('sleep', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3),
            BitStruct('dehumidify', Nibble('rhtg'), Nibble('rclg')),
            Byte('hum_vent_flags'), Array(2, Byte('unknown'))),
        Struct('wake', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3),
            BitStruct('dehumidify', Nibble('rhtg'), Nibble('rclg')),
            Byte('hum_vent_flags'), Array(2, Byte('unknown'))),
        Struct('manual', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3),
            BitStruct('dehumidify', Nibble('rhtg'), Nibble('rclg')),
            Byte('hum_vent_flags'), Array(2, Byte('unknown'))),
    ),
    # zone 1
    '4012' => Struct('vacation_settings',
        Byte('min_temp'), Byte('max_temp'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown')),
    ),

    # MISC1
    '4608' => Struct('insecurity',
        Pointer(4,CString('mac_address')),
        Pointer(24,CString('ssid')),
        Pointer(70,CString('password')),
        Pointer(139,CString('hostname')),
    ),

    '4609' => Struct('server',
        Pointer(0,CString('cloud_host')),
        Pointer(67,CString('proxy_server')),
    ),

    '460A' => Struct('dealer',
        Pointer(0,CString('dealer_name')),
        Pointer(50,CString('dealer_brand')),
        Pointer(70,CString('dealer_url')),
    ),

    '460B' => Struct('wifi_profiles',
        Array(4, Struct('profile',
            PaddedString('ssid', 32, paddir => 'right'),
            Byte('unknown'),
            Byte('flag'),
            Byte('channel'),
            Byte('rssi'),
        )),
    ),

    '460C' => Struct('wifi_scan',
        Array(4, Struct('ap',
            PaddedString('ssid', 32, paddir => 'right'),
            Byte('unknown'),
            Byte('flag'),
            Byte('channel'),
            Byte('rssi'),
        )),
    ),

    # LASTTEN fault history (thermostat table 0x42)
    # Row 2 (72 bytes, R/W): 10 fault entries of 7 bytes each.
    # Cross-referenced against equipment_events XML which provides the same data
    # with human-readable descriptions, timestamps, and source labels.
    #
    # Record structure (7 bytes per entry):
    #   Byte 0:   Fault code (decimal, e.g. 12, 68, 186)
    #   Byte 1:   Source device (0x20=UI/thermostat, 0x40=furnace/IDU, 0x52=AC/ODU)
    #   Byte 2:   Hour (0-23)
    #   Byte 3:   Minute (0-59)
    #   Byte 4-5: Days since 2013-01-01 (big-endian 16-bit).
    #             Why 2013-01-01? Nobody knows. The thermostat firmware apparently
    #             chose this epoch and it matches all observed data perfectly.
    #             A truly bizarre choice — not a standard Unix epoch, not a Carrier
    #             product launch date, not a round number. It just is.
    #   Byte 6:   Bit 7 = active flag (0=active/on, 1=cleared/off)
    #             Bits 0-6 = occurrence count (0-127)
    #             Note: for active faults, occurrence count may differ from the
    #             equipment_events XML value — the thermostat may update it independently.
    '4202' => Struct('lastten',
        Array(10, Struct('fault',
            Byte('code'),
            Enum(Byte('source'),
                UI       => 0x20,
                furnace  => 0x40,
                AC       => 0x52,
                _default_ => $DefaultPass,
            ),
            Byte('hour'),
            Byte('minute'),
            UBInt16('days'),    # days since 2013-01-01
            BitStruct('status',
                Flag('active'),    # 0=active, 1=cleared (inverted sense)
                Flag('occ6'), Flag('occ5'), Flag('occ4'),
                Flag('occ3'), Flag('occ2'), Flag('occ1'), Flag('occ0'),
            ),
            Value('occurrences', sub {
                my $s = $_->ctx->{status};
                ($s->{occ6}<<6) | ($s->{occ5}<<5) | ($s->{occ4}<<4) |
                ($s->{occ3}<<3) | ($s->{occ2}<<2) | ($s->{occ1}<<1) | $s->{occ0}
            }),
        )),
    ),

    # --- Thermostat tables 0x31 INGDATA and 0x41 TEMP ---
    # Float-bearing registers identified by probing live and correlating against
    # ODU/IDU values. Where bytes hold confirmed or clean IEEE754 float32 values
    # they are declared as BFloat32 (even when their physical identity is unknown)
    # so the bytes decode rather than staying undefined.

    # 3107 — High-precision zone ambient temperatures, float32 °F.
    # The float counterpart of 3b02 bytes[3:7] (which carry integer RT).
    '3107' => Struct('zone_temps_float',
        BFloat32('zone1'), BFloat32('zone2'), BFloat32('zone3'), BFloat32('zone4'),
        Array(16, Byte('reserved')),
    ),

    # 310d — 21 float32 values. First 7 (~0.09) and 4 (~0.20) are nonzero;
    # identity unknown but clean IEEE754 (likely PID/filter coefficients).
    '310d' => Struct('ingdata_310d',
        Array(21, BFloat32('value')),
    ),

    # 3117 — Rolling time-series / control buffer. Two small float32 deltas at
    # the head (~0.27), a float32 near the tail (~0.89), mixed byte history
    # between. Changes between reads.
    '3117' => Struct('ingdata_3117',
        BFloat32('delta1'),
        BFloat32('delta2'),
        Array(60, Byte('history')),     # bytes 8..67
        BFloat32('tail_float'),         # byte 68
        Array(2, Byte('reserved')),
    ),

    # 3123 — Cached blower CFM at float32 byte 12 (matches IDU 0306 airflow_cfm).
    # Remaining bytes are integer/flag data of unknown layout.
    '3123' => Struct('ingdata_3123',
        Array(12, Byte('header')),      # bytes 0..11
        BFloat32('blower_cfm'),         # byte 12 — confirmed vs IDU airflow_cfm
        Array(72, Byte('data')),
    ),

    # 4102 (TEMP) — Zone ambient temperatures (float32 °F) at bytes 10..25,
    # preceded by a 10-byte preamble and followed by flags + live float32
    # deltas (bytes 50..65) of unknown identity. Same zone temps as 3107.
    '4102' => Struct('temp_status',
        Array(10, Byte('preamble')),                              # bytes 0..9
        BFloat32('zone1'), BFloat32('zone2'), BFloat32('zone3'), BFloat32('zone4'),   # 10..25
        Array(16, Byte('reserved')),                             # bytes 26..41
        Array(4, Byte('flags')),                                 # bytes 42..45 (observed 01 01 01 01)
        Array(4, Byte('pad')),                                   # bytes 46..49
        BFloat32('delta1'), BFloat32('delta2'), BFloat32('delta3'), BFloat32('delta4'),   # 50..65 (live, unknown)
        Array(19, Byte('tail')),                                 # bytes 66..84
    ),

    # --- Thermostat tables 0x49 SYSCTRL and 0x4A MISC2 ---
    # Float-bearing registers found by a systematic float scan of all tables.
    # Floats are declared even where identity is unknown so the bytes decode.

    # 4903 — Temperature setpoints/limits, two float32 arrays of eight
    # (67/68/60/60/50/50/50/50 and 74/74/77/78/90/90/90/90). Clean °F values,
    # identity unconfirmed. 32-byte zero gap between the two arrays.
    '4903' => Struct('sysctrl_4903',
        Array(8, BFloat32('setpoint1')),                          # bytes 0..31
        Array(32, Byte('reserved')),                             # bytes 32..63 (zero gap)
        Array(8, BFloat32('setpoint2')),                          # bytes 64..95
    ),

    # 490b — Two small float32 values at the head (29.27, 11.12), identity
    # unknown. Rest is integer/flag data.
    '490b' => Struct('sysctrl_490b',
        BFloat32('f0'),
        BFloat32('f1'),
        Array(56, Byte('reserved')),                             # 8..63
        BFloat32('f2'),                                          # 64 (55268 — possibly a counter)
        Array(28, Byte('tail')),                                 # 68..95
    ),

    # 4a04 — Blower/compressor stage curve. Six float32 values
    # (1800/2340/3240/3780/4500/4680 — RPM-like) followed by four float32
    # CFM-like values (904/904/940/940). Pairs of compressor RPM stage points
    # and their corresponding airflow.
    '4a04' => Struct('stage_curve',
        BFloat32('rpm1'), BFloat32('rpm2'), BFloat32('rpm3'),
        BFloat32('rpm4'), BFloat32('rpm5'), BFloat32('rpm6'),    # 0..23
        BFloat32('cfm1'), BFloat32('cfm2'), BFloat32('cfm3'), BFloat32('cfm4'),   # 24..39
        Array(16, Byte('reserved')),                             # 40..55
    ),

};

our %device_parsers;              # keyed by device class name

sub subparser {
    my ($reg, $src) = @_;
    $reg = uc($reg//'');

    # Device-specific first (exact match, then base class)
    # e.g. "OutdoorUnit2" checks OutdoorUnit2, then OutdoorUnit
    for my $device ($src // (), (defined $src && $src =~ /^(.+?)\d+$/ ? $1 : ())) {
        if (exists $device_parsers{$device}) {
            my $p = $device_parsers{$device}{$reg};
            return $p if $p;
        }
    }

    # Fall back to global
    foreach my $key (keys %$parsers) {
        return $parsers->{$key} if $reg =~ /$key$/i;
    }

    return Value("unknown",undef);
}

# Allow device modules to add their parsers (global scope)
sub add_parser {
    my ($class, $reg_pattern, $parser) = @_;
    $parsers->{$reg_pattern} = $parser;
}

# Allow device modules to add device-scoped parsers
sub add_device_parser {
    my ($class, $device_class, $reg_pattern, $parser) = @_;
    $device_parsers{$device_class}{$reg_pattern} = $parser;
}

1;
