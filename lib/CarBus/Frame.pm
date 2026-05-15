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
      my $sp = subparser($_->ctx->{reg_string});
      try { $sp->parse(substr($_->ctx->{payload_raw},3)) } || undef;
  }),
  Value("payload_hex", sub { unpack("H*", $_->ctx->{payload_raw}) }),

  Value("reg_name", sub {
    my $fh = $_->ctx;
    my $subp = subparser($fh->{reg_string});
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
    '01' => Struct('tabledef',
        UBInt16('type'),
        String('name', 8),
        UBInt16('size'),
        Byte('rows'),
        Array(sub { $_->ctx->{rows} },
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

};

sub subparser {
    my $reg = shift;
    $reg = uc($reg//'');
    foreach my $key (keys %$parsers) {
        return $parsers->{$key} if $reg =~ /$key$/i;
    }

    return Value("unknown",undef);
}

# Allow device modules to add their parsers
sub add_parser {
    my ($class, $reg_pattern, $parser) = @_;
    $parsers->{$reg_pattern} = $parser;
}

1;
