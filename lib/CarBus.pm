package CarBus;
use Moo;
use CarBus::Frame;
use Scalar::Util qw/blessed/;

has fh => (is=>'ro', isa=>sub{
    die 'fh must be an IO::Handle or subclass thereof' unless
        defined blessed($_[0]) and $_[0]->isa('IO::Handle');
});
has buffer => (is=>'rw', default=>'');
has name => (is=>'ro', lazy=>1, default => sub {
    return join('-',ref($_[0]->fh), int(rand()*9999));
});

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
                    $self->handlers($cbf);
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

sub samreq {
    my $self = shift;
    my ($table, $row, $frameopts) = @_;
    $frameopts //= {};
    my $samframe = CarBus::Frame->new(
        src=>'FakeSAM', src_bus=>1,
        dst=>'Thermostat', dst_bus=>1,
        cmd=>'read',
        payload_raw=>pack("C*", 0, $table, $row),
        %$frameopts
    );
    $self->write($samframe);
    return $samframe;
}

has devices => (is=>'rw',default=>sub{{}});
has registers => (is=>'rw',default=>sub{{}});

sub handlers {
    my $self = shift;
    my $frame = shift;
    my $fs = $frame->struct;
    if (my $src = $fs->{src} and $fs->{cmd} eq 'reply') {
        $self->devices->{$src}//={} ;
        $self->devices->{$src}->{$fs->{reg_string}}//={  payload_hex=>$fs->{payload_hex} } if $fs->{reg_string};
        $self->devices->{$src}->{$fs->{reg_string}}->{paylpad} = $fs->{payload} if $fs->{payload};
    }
    # mangle frame contents;
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
            foreach my $dstbus (@{$self->buslist}) {
                next if $srcbus == $dstbus;
                $dstbus->write($frame);
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
