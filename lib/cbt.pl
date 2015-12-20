#!/usr/bin/perl
use CarBus;
use IO::Termios;
use Data::Dumper;

#$Data::ParseBinary::print_debug_info = 1;
use IO::File;

#my $sfh = new IO::File("tty.raw");
my $sfh = new IO::File("ttysync.raw");
#my $sfh = IO::Termios->open("/dev/ttyUSB0","38400,8,n,1");

my $carbus = new CarBus($sfh);

while(1) {
	my $frame = $carbus->get_frame();
	print Dumper($frame);
	exit if $frame->{error};
}

