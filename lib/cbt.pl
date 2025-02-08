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

my $lt=0;
#$sam->handlers([
#    sub{
#        my $self = shift; my $frame=shift;
#        use DDP;
#        p $frame->frame_log;
#        p $frame->frame_hex;
#        p $frame->struct;
#        warn "----------";
#        if (time>$lt+10) {
#            p $self->devices;
#            $lt=time;
#        }
#    }
#]);

my $bridge = CarBus::Bridge->new(buslist=>[$sam,$net]);
my $i;
use DDP;
while(1) {
    foreach my $frame ($bridge->drive) {
        say $frame->frame_log if $frame->frame_log =~ /SAM/;
    }
    if (time>$i+3) {
        $i=time;
        p $sam->devices;
        p $net->devices;
    }
}

