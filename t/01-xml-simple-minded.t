use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

BEGIN {
	use_ok('XML::Simple::Minded');
}

my $xml = XML::Simple::Minded->new("<this that=\"option\">valueforthis</this>");
isa_ok($xml, 'XML::Simple::Minded');
is($xml->this->content,'valueforthis', 'contents');
is($xml->this->that,'option','attributes');
$xml = undef;

$xml = XML::Simple::Minded->new("$FindBin::Bin/systems17.raw");
is($xml->system->config->mode,'auto','XML parses');

$xml->system->config->testitem(['test value']);
is($xml->system->config->testitem,'test value','New values added');

my $xml_string = $xml."";
ok($xml_string =~ m/^<\?xml/,'xml stringifies definition');
ok($xml_string =~ m/<\/system>$/,'xml stringifies system');
ok($xml_string =~ m/<testitem>test value<\/testitem>/,'new test item added');

my $xml2 = XML::Simple::Minded->new($xml_string);
is($xml_string, $xml2.'', 'XML is unmangled');

done_testing();
