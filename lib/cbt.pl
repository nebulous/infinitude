#!/usr/bin/perl
use strict;
use CarBus;
use Data::Dumper;
use IO::File;
use IO::Socket::IP;
use IO::Termios;

my $carbus = new CarBus(async=>1);
#my $sfh = new IO::File("somedumpfile.raw"); # dumpfile
#my $sfh = IO::Termios->open("/dev/ttyUSB0","38400,8,n,1"); #serial port
my $sfh = IO::Socket::IP->new(PeerHost=>'192.168.1.47', PeerPort=>23); #tcp

my $buffer = '';
while(1) {
	$sfh->recv($buffer, 128);
	$carbus->push_stream($buffer);
	my $frame = $carbus->get_frame();
	unless ($frame->{error}) {
		print Dumper($frame);
	}
}

