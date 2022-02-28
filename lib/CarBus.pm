package CarBus;
use Moo;
use CarBus::Frame;

has async => (is=>'ro', default=>sub{0});
has fh => (is=>'rw');
has buffer => (is=>'rw', default=>'');
has fill_buffer => (is=>'ro', default=>sub{ 
		my $self = shift; 
		$self->fh ? $self->fh_fill : sub{};
	});

use constant MAX_BUFFER => 512;

sub BUILDARGS {
  my ( $class, @args ) = @_;
  unshift @args, "fh" if @args % 2 == 1;
  return { @args };
};

sub get_frame {
	my $self = shift;
	my $max_attempts = $self->async ? $self->buflen : MAX_BUFFER;
	my $attempts = 0;
	while ($attempts++<$max_attempts) {
		my $data_len = $self->buflen>4 ? ord(substr($self->buffer,4,1)) : 0;
		if ($data_len>0) {
			my $frame_len = 10+$data_len;
			if ($self->buflen>=$frame_len) {
				my $frame_string = substr($self->buffer,0,$frame_len);
                my $cbf = CarBus::Frame->new($frame_string);
				if ($cbf->valid) {
					$self->shift_stream($frame_len);
                    return $cbf;
				}
				$self->shift_stream(1);
			}
		} else {
			$self->shift_stream(1);
		}
		$self->fill_buffer();
	}
	return { error=>'timed out or EOF' };
}

sub fh_fill {
	my $self = shift;
	my $buf = '';
	my $len = $self->fh->sysread($buf, 266); #255+10
	$self->push_stream($buf);
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

1;
