package CarBus;
use Moo;
use CarBus::Frame;
use CarBus::SAM;
use Scalar::Util qw/blessed/;
use IO::Select;

has fh => (is=>'ro', isa=>sub{
    die 'fh must be an IO::Handle or subclass thereof' unless
        defined blessed($_[0]) and $_[0]->isa('IO::Handle');
});
has iosel => ( is=>'ro', lazy=>1, default=>sub{
    my $self = shift;
    return IO::Select->new($self->fh);
});
has buffer => (is=>'rw', default=>'');
has name => (is=>'ro', lazy=>1, default => sub {
    return join('-',ref($_[0]->fh), int(rand()*9999));
});
has devices => (is=>'rw',default=>sub{{}});
has handlers => (is=>'rw', default=>sub{[\&_track_registers]});

use constant MIN_FRAME => 10;
use constant MAX_FRAME => 266;
use constant MAX_BUFFER => 2*MAX_FRAME;

sub BUILDARGS {
  my ( $class, @args ) = @_;
  unshift @args, "fh" if @args % 2 == 1;
  my $argref = { @args };
  $argref->{fh}->blocking(0);
  return $argref;
};


sub get_frame {
    my $self = shift;
    my $string = shift;
    $self->push_stream($string) if $string;

    my $attempts = 0;
    $self->fh_fill() unless $string;
    return unless $self->buflen >= MIN_FRAME;

    while ($attempts++ < $self->buflen) {
        my $data_len = ord(substr($self->buffer,4,1));
        my $frame_len = MIN_FRAME+$data_len;
        if ($self->buflen >= $frame_len ) {
            if (my $frame_string = substr($self->buffer,0,$frame_len)) {
                my $cbf = CarBus::Frame->new($frame_string);
                if ($cbf->valid) {
                    $self->shift_stream($frame_len);
                    $self->run_handlers($cbf);
                    $cbf->{busname} = $self->name;
                    return $cbf;
                }
            }
            $self->shift_stream(1);
        }
        $self->fh_fill() unless $string;
    }
    return undef;
}

sub fh_fill {
    my $self = shift;
    return unless $self->fh;
    return unless $self->iosel->can_read(0.05); #100 read checks per second
    my $buf = '';
    my $len = $self->fh->sysread($buf, MAX_BUFFER-$self->buflen);
    $self->push_stream($buf) if defined $len;
    return $len;
}

sub buflen {
	my $self = shift;
	return length($self->buffer);
}

sub push_stream {
	my $self = shift;
	my ($input) = @_;
	return unless defined $input;
	$self->buffer($self->buffer().$input);
	$self->shift_stream($self->buflen - MAX_BUFFER);
}

sub shift_stream {
	my $self = shift;
	my ($byte_num) = @_;
	return if $byte_num<1;
	$byte_num = $self->buflen if $self->buflen<$byte_num;
	$self->buffer(substr($self->buffer,$byte_num));
}

sub write {
    my $self = shift;
    my $frame = shift;
    $self->fh->syswrite($frame->struct->{raw});
}

# Generic read - works for any device
sub read_register {
    my $self = shift;
    my ($dst, $table, $row, $opt) = @_;
    $opt //= {};
    my $frame = CarBus::Frame->new(
        src     => $opt->{src} // 'FakeSAM',
        src_bus => $opt->{src_bus} // 1,
        dst     => $dst,
        dst_bus => $opt->{dst_bus} // 1,
        cmd     => 'read',
        payload_raw => pack("C*", 0, $table, $row),
    );
    $self->write($frame);
    return $frame;
}

# Generic write - works for any device
sub write_register {
    my $self = shift;
    my ($dst, $table, $row, $value, $opt) = @_;
    $opt //= {};
    my $frame = CarBus::Frame->new(
        src     => $opt->{src} // 'FakeSAM',
        src_bus => $opt->{src_bus} // 1,
        dst     => $dst,
        dst_bus => $opt->{dst_bus} // 1,
        cmd     => 'write',
        payload_raw => pack("C*", 0, $table, $row) . $value,
    );
    $self->write($frame);
    return $frame;
}

# Legacy method - now uses read_register
# Interrogates Thermostat registers
sub samreq {
    my $self = shift;
    my ($table, $row, $frameopts) = @_;
    return $self->read_register('Thermostat', $table, $row, $frameopts);
}


sub device_names {return [keys %{shift->devices}] }

# Default handler to track device registers
sub _track_registers {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    $self->devices->{$fs->{src}}//={} ;
    if ($fs->{payload_hex} ne '00'.($fs->{reg_string}||'')) {
        $self->devices->{$fs->{src}}->{$fs->{reg_string}}//={  payload_hex=>$fs->{payload_hex} } if $fs->{reg_string};
        $self->devices->{$fs->{src}}->{$fs->{reg_string}}->{payload} = $fs->{payload} if $fs->{payload};
    }
}

sub run_handlers {
    my $self = shift;
    my $frame = shift;
    foreach my $handler (@{ $self->handlers }) {
        $handler->($self, $frame);
    }
}



package CarBus::Bridge;
use Moo;

has buslist => (is=>'ro');

sub drive {
    my $self = shift;
    my @frames = ();
    foreach my $srcbus (@{$self->buslist}) {
        if (my $frame = $srcbus->get_frame()) {
            push(@frames,$frame);
            # Skip forwarding if both src and dst are on the source bus
            next if exists $srcbus->devices->{ $frame->struct->{src} }
                and exists $srcbus->devices->{ $frame->struct->{dst} };
            foreach my $dstbus (@{$self->buslist}) {
                next if $srcbus == $dstbus;
                my $write = 0;
                $write ||= 'broadcast' if $frame->struct->{dst} eq 'Broadcast';
                $write ||= 'device' if $dstbus->devices->{ $frame->struct->{dst} };
                $write ||= 'new' unless scalar @{$dstbus->device_names};
                #p $frame->struct if $write;
                $dstbus->write($frame) if $write;
            }
        }
    }
    return @frames;
}

sub write {
    my $self = shift;
    my $frame = shift;
    $_->write($frame) for @{$self->buslist};
}

1;
