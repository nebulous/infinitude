#!/usr/bin/perl

use strict;
use feature 'say';
use CarBus;
use IO::File;
use IO::Socket::IP;
use IO::Termios;

#my $sfh = CarBus->new(IO::File->new("net.log",'r')); # dumpfile
my $net = CarBus->new(IO::Socket::IP->new(PeerHost=>'192.168.1.23', PeerPort=>23)); #tcp
my $sam = CarBus->new(IO::Termios->open("/dev/cu.usbserial-A7039O5G","38400,8,n,1")); #serial port

my $bridge = CarBus::Bridge->new(buslist=>[$sam,$net]);

while(1) {
    foreach my $frame ($bridge->drive) {
        say $frame->frame_log;
    }
}

