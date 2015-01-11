package Cache::FileDump;
# Simple file store implementation.
# Any CHI or Cache::Cache or key/value store should work
use Moo;
has base =>(is=>'rw', default=>'.');
has store => (is=>'rw', default=>sub{{}});
sub set {
	my $self = shift;
	my ($key, $value) = @_;
	$value = $value.'';
	my $stored = $self->get($key) || '';
	if (!exists($self->store->{$key}) or $stored ne $value) {
		my $F;
		if (open($F,">".$self->base."/$key")) {
			print $F $value;
			close $F;
		}
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
	return $value;
}
1;
