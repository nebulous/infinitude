package CarBus::Frame;
use strict;
use warnings;
use Data::ParseBinary;
use Digest::CRC 'crc16';

my %device_classes = (
	Thermostat => 0x20,
	Furnace => 0x40,
	FanCoil => 0x42,
	HeatPump => 0x50,
	HeatPump => 0x51,
	SAM => 0x92,
	SystemInit => 0x1F,
	_default_ => $DefaultPass
);

our $frame_parser = Struct("CarFrame", 
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
	Field("data", sub { $_->ctx->{length}; }),
	UBInt16("checksum", _default_=>1),
	Value("rawframe", sub {
		if (ref($_->stream)=~/reader/i) {
			my $length = $_->ctx->{length} + 10;
			my $start = $_->stream->tell - $length;
			$_->stream->seek($start);
			return $_->stream->ReadBytes($length);
		}
		return '';
	}),
	Value("valid", sub { (crc16($_->ctx->{rawframe}) == 0) ? 1 : 0; }),
);

use Exporter;
our @ISA = qw/Exporter/;
our @EXPORT = qw/$frame_parser/;

1;
