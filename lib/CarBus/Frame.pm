package CarBus::Frame;
use Moo;
use Data::ParseBinary;
use Digest::CRC 'crc16';

my %device_classes = (
	SystemInit => 0x1F,
	NIM => 0x80,
	SAM => 0x92,
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
    Value("table", sub { length($_->ctx->{data})>=3 ? ord(substr($_->ctx->{data}, 1,1)) : 0 }),
    Value("row",   sub { length($_->ctx->{data})>=3 ? ord(substr($_->ctx->{data}, 2,1)) : 0 }),
);


around BUILDARGS => sub {
    my ( $orig, $class, @args ) = @_;


    my $defaults = {
        DstClass => 'Thermostat', DstAddress=>1,
        SrcClass => 'SAM', SrcAddress=>1,
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
    return $self->parser->parse($self->frame);
}

sub parser_for {
    my $table = shift;

    my $ps = {
        1 => Struct('tabledef',
            Byte("bus"), Byte("table"), Byte("row"),
            ULInt16('type'),
            String('name', 8),
            ULInt16('size'),
            Byte('rows'),
            Array(sub { $_->ctx->{rows} },
                Struct("rowdef",
                    Byte("size"),
                    Byte("flags")
                )
            )
        ),

        4 => Struct('device_info',
            Byte("bus"), Byte("table"), Byte("row"),
            PaddedString('device', 24, paddir=>'right'),
            PaddedString('location', 24, paddir=>'right'),
            PaddedString('software', 16, paddir=>'right'),
            PaddedString('model', 20, paddir=>'right'),
            PaddedString('serial', 12, paddir=>'right'),
            PaddedString('reference', 24, paddir=>'right'),
        )
    };
    return $ps->{$table};
}

1;
