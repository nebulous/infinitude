package CarBus::Frame;
use Moo;
use Data::ParseBinary;
use Digest::CRC 'crc16';
use Try::Tiny;

my %device_classes = (
	SystemInit => 0x1F,
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

has parser => (is=>'ro', default=> sub { $fp });
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

my $parsers = {
    '01' => Struct('tabledef',
        UBInt16('type'),
        String('name', 8),
        UBInt16('size'),
        Byte('rows'),
        Array(sub { $_->ctx->{rows} },
            Struct("rowdef",
                Byte("size"),
                Enum(Byte("flags"), 'read'=>1, 'write'=>2,'read/write'=>3, _default_ => $DefaultPass)
            )
        )
    ),

    '0104' => Struct('device_info',
        PaddedString('device', 24, paddir=>'right'),
        PaddedString('location', 24, paddir=>'right'),
        PaddedString('software', 16, paddir=>'right'),
        PaddedString('model', 20, paddir=>'right'),
        PaddedString('serial', 12, paddir=>'right'),
        PaddedString('reference', 24, paddir=>'right'),
    ),

    '0202' => Struct('time', Byte('hour'), Byte('minute'), Enum(Byte('weekday'), Sunday=>0, Monday=>1, Tuesday=>2, Wednesday=>3, Thursday=>4, Friday=>6, Saturday=>6)),

    '0203' => Struct('date', Byte('day'), Byte('month'), Byte('20xx'), Value('year', sub { 2000+int($_->ctx->{'20xx'}) })),


    # SAMINFO
    '3B02' => Struct('sam_state',
        Byte('active_zones'),
        Padding(2),
        Array(8, Byte('temperature')),
        Array(8, Byte('humidity')),
        Padding(1),
        Byte('oat'),
        BitStruct('zones_unoccupied',
            Flag('z8'), Flag('z7'), Flag('z6'), Flag('z5'),
            Flag('z4'), Flag('z3'), Flag('z2'), Flag('z1'),
        ),
        BitStruct('stagmode',
            Nibble('stage'),
            Enum(Nibble('mode'), heat=>0, cool=>1, auto=>2, eheat=>3, off=>4)
        ),
        Array(2, Byte('unknown')),
        Enum(Byte('weekday'), Sunday=>0, Monday=>1, Tuesday=>2, Wednesday=>3, Thursday=>4, Friday=>6, Saturday=>6),
        UBInt16('minutes_since_midnight'),
        Byte('displayed_zone')
    ),

    '3B03' => Struct('sam_zones',
        Byte('active_zones'),
        Padding(2),
        Array(8, Enum(Byte('fan_mode'), high=>3, medium=>2, low=>1, auto=>0 )),
        BitStruct('zones_holding',
            Flag('z8'), Flag('z7'), Flag('z6'), Flag('z5'),
            Flag('z4'), Flag('z3'), Flag('z2'), Flag('z1'),
        ),
        Array(8, Byte('heat_setpoint')),
        Array(8, Byte('cool_setpoint')),
        Array(8, Byte('humidity_setpoint')),
        Byte('speed_controlled_fan'),
        Byte('hold_timer'),
        Array(8, UBInt16('hold_duration')),
        Array(8, Field('zone_name', 12))
    ),

    '3B04' => Struct('sam_vacation',
        Byte('active'),
        UBInt16('hours'),
        Byte('min_temp'),
        Byte('max_temp'),
        Byte('min_humidity'),
        Byte('max_humidity'),
        Byte('fan_mode')
    ),

    '3B05' => Struct('sam_accessories',
        Padding(3),
        Byte('filter_consumption'),
        Byte('uv_consumption'),
        Byte('humidifier_consumption'),

        Enum(Byte('filter_reminders'), off=>0, on=>1),
        Enum(Byte('uv_reminders'), off=>0, on=>1),
        Enum(Byte('humidifier_reminders'), off=>0, on=>1),
    ),


    '3B06' => Struct('sam_dealer',
        Byte('backlight'),
        Byte('auto_mode'),
        Padding(1),
        Byte('deadband'),
        Byte('cycles_per_hour'),
        Byte('schedule_periods'),
        Byte('programs_enabled'),
        Byte('temp_units'),
        Pointer(15,CString('dealer_name')),
        Pointer(35,CString('dealer_phone')),
    ),

    # zone 1
    '4002' => Struct('schedule',
        Array(7, Array(5, Struct('chunk',@schedchunk)))
    ),
    # zone 1
    '400A' => Struct('comfort_profile',
        Struct('home', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('away', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('sleep', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('wake', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('manual', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
    ),
    # zone 1
    '4012' => Struct('vacation_settings',
        Byte('min_temp'), Byte('max_temp'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown')),
    ),

    # MISC1
    '4608' => Struct('insecurity',
        Pointer(7,CString('mac_address')),
        Pointer(27,CString('ssid')),
        Pointer(73,CString('password')),
        Pointer(142,CString('token?')),
    ),

    '4609' => Struct('server',
        Pointer(3,CString('cloud_host')),
        Pointer(70,CString('device_ip')),
    )

};

sub subparser {
    my $reg = shift;
    $reg = uc($reg//'');
    foreach my $key (keys %$parsers) {
        return $parsers->{$key} if $reg =~ /$key$/i;
    }

    return Value("unknown",undef);
}

1;
