package CarBus::SAM;
use Moo;

has registers=>(is=>'ro', default=>sub{{}});

sub handler {
    my $self = shift;
    my $frame = shift;
    use DDP;
    p $frame->frame_log;
}

1;
