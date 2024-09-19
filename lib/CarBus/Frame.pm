package CarBus::Frame;
use Moo;
use Data::ParseBinary;
use Digest::CRC 'crc16';
use Try::Tiny;

my %device_classes = (
	SystemInit => 0x1F,
	NIM => 0x80,
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
};

foreach my $pre (keys %$classmap) {
    my $label = $classmap->{$pre};
    my $idx=0;
    while($idx<0xF) {
        my $addr = ($pre<<4) + $idx;
        $device_classes{$label.($idx ? $idx : '')} = $addr;
        $idx++;
    }
}

my $frame_parser = Struct("CarFrame",
    Enum(Byte("DstClass"), %device_classes),
    Byte("DstAddress"),
    Enum(Byte("SrcClass"), %device_classes),
    Byte("SrcAddress"),
    Byte("length"),
    Padding(2),
    Enum(Byte("Function"),
        reply => 0x06,
        read => 0x0B,
        write => 0x0C,
        exception => 0x15,
        _default_ => $DefaultPass
    ),
    Field("data", sub { $_->ctx->{length} }),
    ULInt16("checksum"),
    Value("bus",   sub { length($_->ctx->{data})>=3 ? ord(substr($_->ctx->{data}, 0,1)) : 0 }),
    Value("table", sub { length($_->ctx->{data})>=3 ? ord(substr($_->ctx->{data}, 1,1)) : 0 }),
    Value("row",   sub { length($_->ctx->{data})>=3 ? ord(substr($_->ctx->{data}, 2,1)) : 0 }),
);

around BUILDARGS => sub {
    my ( $orig, $class, @args ) = @_;


    my $defaults = {
        DstClass => 'Thermostat', DstAddress=>1,
        SrcClass => 'FakeSAM', SrcAddress=>1,
        Function => 'read',
        checksum => 0,
        length => 0,
        data => '',
    };

    if (@args == 1 && !ref $args[0]) {
        my $parsed_frame = $frame_parser->parse($args[0]);
        my $check_frame = __PACKAGE__->new($parsed_frame);
        return {
            struct => $check_frame->struct,
            valid  => ($args[0] eq $check_frame->frame) ? 1 : 0
        };
    }

    (@args) = %{$args[0]}
      if @args == 1 && ref $args[0];

    my $struct = $defaults;
    my %arghash = @args;
    foreach my $key (keys %arghash) {
        $struct->{$key} = delete $arghash{$key} if defined($defaults->{$key});
    }

    $arghash{struct} = $struct;

    return $class->$orig(%arghash);
};

has parser => (is=>'ro', default=> sub { $frame_parser });
has struct => (is=>'rw');
has valid => (is=>'ro', default=>sub{1});

sub frame {
    my $self = shift;
    return undef unless $self->valid;
    $self->struct->{length} = length($self->struct->{data});
    my $fstring = substr $self->parser->build($self->struct), 0, -2;
    $self->struct->{checksum} = crc16($fstring);
    return $fstring.pack("S",$self->struct->{checksum});
}

sub frame_hex {
    my $self = shift;
    return unpack("H*", $self->frame);
}

sub frame_hash {
    my $self = shift;
    my $parsed = $self->parser->parse($self->frame);
    return {} unless $parsed;

    my $register = sprintf("%02x%02x",$parsed->{table}, $parsed->{row});
    $parsed->{register} = $register;
    if (my $regparser = $self->reg_parser($register)) {
        $parsed->{type} = $regparser->{Name};
        try {
            $parsed->{payload} = $regparser->parse($parsed->{data});
        };
    }

    return $parsed;
}

sub frame_log {
    my $self = shift;
    return join(' ',
        $self->frame_hash->{SrcClass},
        $self->frame_hash->{Function},
        $self->frame_hash->{DstClass},
        $self->frame_hash->{register}
    );
}

my @regdef = (Byte("bus"), Byte("table"), Byte("row"));
my @schedchunk = (
    Byte('min15s'), Enum(Byte('mode'), home=>0, away=>1, sleep=>2, wake=>3),
    Value('enabled', sub { $_->ctx->{min15s} == 0x60 ? 0 : 1 }),
    Value("time", sub { sprintf("%02d:%02d", int($_->ctx->{min15s}/4), 15*int($_->ctx->{min15s}%4)) }),
    );

my $parsers = {
    '01' => Struct('tabledef',
        @regdef,
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
        @regdef,
        PaddedString('device', 24, paddir=>'right'),
        PaddedString('location', 24, paddir=>'right'),
        PaddedString('software', 16, paddir=>'right'),
        PaddedString('model', 20, paddir=>'right'),
        PaddedString('serial', 12, paddir=>'right'),
        PaddedString('reference', 24, paddir=>'right'),
    ),

    '0202' => Struct('time', @regdef, Byte('hour'), Byte('minute'), Byte('unknown')),
    '0203' => Struct('date', @regdef, Byte('day'), Byte('month'), Byte('20xx'), Value('year', sub { 2000+int($_->ctx->{'20xx'}) })),


    # SAMINFO
    '3B02' => Struct('sam_state', @regdef,
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

        Nibble('stage'),
        Nibble('mode'),
        Array(5, Byte('unknown')),
        Byte('displayed_zone')
    ),

    '3B03' => Struct('sam_zones', @regdef,
        Byte('active_zones'),
        Padding(2),
        Array(8, Byte('fan_mode')),
        Byte('zones_holding'),
        Array(8, Byte('heat_setpoint')),
        Array(8, Byte('cool_setpoint')),
        Array(8, Byte('humidity_setpoint')),
        Byte('speed_controlled_fan'),
        Byte('hold_timer'),
        Array(8, UBInt16('hold_duration')),
        Array(8, Field('zone_name', 12))
    ),

    '3B04' => Struct('sam_vacation', @regdef,
        Byte('active'),
        UBInt16('hours'),
        Byte('min_temp'),
        Byte('max_temp'),
        Byte('min_humidity'),
        Byte('max_humidity'),
        Byte('fan_mode')
    ),

#3B05
#   contains: filterlevel,uvlevel,humidifierpadelvel, reminders for all

    '3B05' => Struct('sam_accessories', @regdef,
        Padding(3),
        Byte('filter_consumption'),
        Byte('uv_consumption'),
        Byte('humidifier_consumption'),

        Enum(Byte('filter_reminders'), off=>0, on=>1),
        Enum(Byte('uv_reminders'), off=>0, on=>1),
        Enum(Byte('humidifier_reminders'), off=>0, on=>1),
    ),


#3B06
# contains: deadband, dealer name, dealer phone
    '3B06' => Struct('sam_dealer', @regdef,
        Pointer(15,CString('dealer_name')),
        Pointer(35,CString('dealer_phone')),
    ),


    # zone 1
    '4002' => Struct('schedule',
        @regdef,
        Array(7, Array(5, Struct('chunk',@schedchunk)))
    ),
    # zone 1
    '400A' => Struct('comfort_profile',
        @regdef,
        Struct('home', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('away', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('sleep', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('wake', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
        Struct('manual', Byte('heat'), Byte('cool'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown'))),
    ),
    # zone 1
    '4012' => Struct('vacation_settings',
        @regdef,
        Byte('min_temp'), Byte('max_temp'), Enum(Byte('fan'), off=>0, low=>1, med=>2, high=>3), Array(4,Byte('unknown')),
    ),

    # MISC1
    '4608' => Struct('insecurity', @regdef,
        Pointer(7,CString('mac_address')),
        Pointer(27,CString('ssid')),
        Pointer(73,CString('password')),
        Pointer(142,CString('token?')),
    ),

    '4609' => Struct('server', @regdef,
        Pointer(3,CString('cloud_host')),
        Pointer(70,CString('device_ip')),
    )

};

sub reg_parser {
    my $self = shift;
    my $reg = shift;
    $reg = uc($reg);
    foreach my $key (keys %$parsers) {
        return $parsers->{$key} if $reg =~ /$key$/i;
    }
}

1;
