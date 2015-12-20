package Cache::FileDump;

our $VERSION = '0.02';

# Simple file store implementation.
# Any CHI or Cache::Cache or key/value store should work better
use Moo;
use Data::Dumper;
has base =>(is=>'rw', default=>'.');
has store => (is=>'rw', default=>sub{{}});
has default_expires_in => (is=>'ro', default=>sub{ 'never' });
has _exp_cache => (is=>'rw', default=>sub{{}});

has _serializer => (is=>'ro', default=>sub { return sub {
		my $obj = shift;
		my $dumper = Data::Dumper->new([]);
		$dumper->Terse(1);
		$dumper->Values([$obj]);
		return $dumper->Dump;
	}
});

has _deserializer => (is=>'ro', default=>sub{ return sub {
		my $str = shift||'';
		my $out = eval $str;
		return $out;
	}
});

sub set {
	my $self = shift;
	my ($key, $value, $exp) = @_;
	my $ser = $self->_serializer;
	$value = &$ser($value).'';
	$exp ||= $self->default_expires_in;
	my $stored = $self->get($key) || '';
	if (!exists($self->store->{$key}) or $stored ne $value) {
		my $F;
		if (open($F,">".$self->base."/$key")) {
			print $F $value;
			close $F;
		}
	}
	if ($exp =~ /^\d+$/) {
		$self->_exp_cache->{$key} = (time+$exp);
	}
	$self->store->{$key} = $value;
}

sub get {
	my $self = shift;
	my ($key) = @_;
	my $value = $self->store->{$key};
	if (!defined($value)) {
		my $F;
		if (open($F, $self->base."/$key")) {
			$value = do { local $/ = <$F> };
			$self->store->{$key} = $value;
		}
	}
	
	if (defined($value)) {
		my $exp = $self->_exp_cache->{$key};
		if (defined($exp)) {
			if (time>$exp) {
				$value = undef;
				delete $self->store->{$key};
				delete $self->_exp_cache->{$key};
			}
		}
	}
	my $des = $self->_deserializer();
	return &$des($value);
}
1;
