package XML::Simple::Minded;
use Moo;
use XML::Simple;
use Hash::AsObject;
use JSON -convert_blessed_universally;
extends qw/XML::Simple/;

our $VERSION = '0.01';

$XML::Simple::PREFERRED_PARSER = 'XML::Parser';

has _xml => (is=>'rw', default=>sub{''});
has _struc => (is=>'rw', default=>sub{{}});
has _root => (is=>'rw');
has _parent => (is=>'rw');
has _depth => (is=>'ro', default=>0);

sub FOREIGNBUILDARGS {
	return (force_array=>1, keep_root=>1, key_attr=>[]);
}

sub BUILDARGS {
  my ( $class, @args ) = @_;
	if (@args % 2 == 1) {
		if (ref($args[0]) eq 'HASH') {
			unshift @args, "_struc";
		} else {
			unshift @args, "_xml";
		}
		push(@args, _root=>1 );
	}
  return { @args };
};

sub BUILD {
	my $self = shift;
	$self->_struc($self->XMLin($self->_xml)) if $self->_xml;
	$self->_struc(Hash::AsObject->new($self->_struc));
}

sub DESTROY {
	my $self = shift;
}

sub TO_JSON {
	my $self = shift;
	return $self->_struc();
}

sub _as_json {
	my $self = shift;
	return to_json($self->TO_JSON, {convert_blessed=>1});
}


use overload '""' => sub {
	my $self = shift;
	my $json = $self->_as_json();
	my $rstruc = $json eq 'null' ? undef : from_json($json);

	{
		package XML::Simple::Minded::Sorter;
		use XML::Simple;
		use base 'XML::Simple';
		sub sorted_keys {
			my $self = shift;
			my ($name, $hashref) = @_;

			my @out;
			my @one;
			my @two;
			foreach my $k (sort keys %$hashref) {
				my $v = $hashref->{$k};
				if (ref($v) eq 'ARRAY' and scalar(@$v) == 1) {
					$v = $v->[0];
					if (!ref($v) or (ref($v) eq 'HASH' and !keys %$v)) {
						unshift @one, $k;
					} else {
						unshift @two, $k;
					}
				} else {
					push @two, $k;
				}
			}
			@out = (sort(@one), sort(@two));
			return @out;
		}
		1;
	}
	my $sx = XML::Simple::Minded::Sorter->new( keep_root=>$self->_root ? 1 : 0, xml_decl=>'<?xml version="1.0" encoding="UTF-8"?>', no_indent=>1 );
	my $xml_string = $sx->XMLout($rstruc);
	$xml_string =~ s/<(\w+)><\/(\w+)>/&selfclose($1,$2)/gse;
	sub selfclose {
		my ($one, $two) = @_;
		return ($one eq $two) ? "<$one/>" : "<$one></$two>"
	}
	return $xml_string;
};

our $AUTOLOAD;
sub AUTOLOAD {
	my $self = shift;
	my $search = $AUTOLOAD;
	$search =~ s/XML::Simple::Minded:://;
	die 'Suspicious recursion' if $self->_depth>99;

	sub haso {
		my ($in, $parent) = @_;
		my $ref = ref($in);

		if ($ref eq 'ARRAY') {
			return &haso($in->[0], $parent) if scalar(@$in) == 1;
			foreach my $e (@$in) {
				$e = &haso($e, $parent);
			}
			return $in;
		}
		if ($ref eq 'HASH' or $ref eq 'Hash::AsObject') {
			return XML::Simple::Minded->new(_struc=>$in, _parent=>$parent, _depth=>$parent ? ($parent->_depth+1) : 0);
		}
		return $in;
	};

	if (@_) {
		my $old = $self->_struc->$search;
		$self->_struc->$search(@_);
		if ($self->_parent) {
			my $key = $self->_root;
			$self->_parent->$key([$self->_struc]) if $key;
		}
	}
	my $res = $self->_struc->{$search};
	if (!defined($res)) {
		return XML::Simple::Minded->new(_root=>$search, _parent=>$self, _depth=>99);
	}
	return &haso($res,$self);
}

1;
