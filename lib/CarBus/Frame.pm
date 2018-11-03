package CarBus::Frame;
use strict;
use warnings;
use Data::ParseBinary;
use Digest::CRC 'crc16';

my %device_classes = (
	SystemInit => 0x1F,
	Thermostat => 0x20,
	Furnace => 0x40,
	FanCoil => 0x42,
	HeatPump0 => 0x50,
	HeatPump1 => 0x51,
	HeatPump2 => 0x52,
	SAM => 0x92,
	Broadcast => 0xF1,
	_default_ => $DefaultPass
);

our $raw_frame_parser = Struct("RawFrame",
	Peek(Byte("length"), 4),
	Field("frame", sub{ $_->ctx->{length}+10 }),
	Value("valid", sub { (crc16($_->ctx->{frame}) == 0 and $_->ctx->{length}>0) ? 1 : 0; }),
);

our $frame_parser = Struct("CarFrame", 
	Enum(Byte("DstClass"), %device_classes),
	Byte("DstAddress"),
	Enum(Byte("SrcClass"), %device_classes),
	Byte("SrcAddress"),
	Byte("length"),
	Padding(2),
	Enum(Byte("Function"), 
		ACK02 => 0x02,
		ACK06 => 0x06,
		READ_TABLE_BLOCK => 0x0B,
		WRITE_TABLE_BLOCK => 0x0C,
		CHANGE_TABLE_NAME => 0x10,
		NACK => 0x15,
		ALARM_PACKET => 0x1E,
		READ_OBJECT_DATA => 0x22,
		READ_VARIABLE => 0x62,
		WRITE_VARIABLE => 0x63,
		AUTO_VARIABLE => 0x64,
		READ_LIST => 0x75,
		_default_ => $DefaultPass
	),
	Field("data", sub { $_->ctx->{length}; }),
	UBInt16("checksum", _default_=>1),
);

use Exporter;
our @ISA = qw/Exporter/;
our @EXPORT = qw/$frame_parser $raw_frame_parser/;

1;
