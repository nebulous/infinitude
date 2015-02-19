use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

BEGIN {
	use_ok('XML::Simple::Minded');
}

my $xml = XML::Simple::Minded->new("$FindBin::Bin/systems17.raw");
isa_ok($xml, 'XML::Simple::Minded');

is($xml->system->config->mode,'auto');

$xml->system->config->testitem(['test value']);
is($xml->system->config->testitem,'test value');

my $xml_string = $xml."";
ok($xml_string =~ m/^<\?xml/,'xml stringifies definition');
ok($xml_string =~ m/<\/system>$/,'xml stringifies system');
ok($xml_string =~ m/<testitem>test value<\/testitem>/,'new test item added');

my $xml2 = XML::Simple::Minded->new($xml_string);
is($xml_string, $xml2.'', 'XML is unmangled');

done_testing();
