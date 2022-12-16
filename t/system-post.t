use Test::More tests=>9;
use Test::Mojo;

# Include application
use FindBin;
use lib "$FindBin::Bin/../lib";
use CHI;

require "$FindBin::Bin/../infinitude";
$main::config = { app_secret => 'testing', pass_reqs=>0 };
$main::store = CHI->new(driver=>'Memory', global=>1);

use XML::Simple::Minded;

# Allow 302 redirect responses
my $t = Test::Mojo->new;
$t->ua->max_redirects(1);

$t->get_ok('/')->status_is(200);
$t->get_ok('/Alive')->status_is(200);
$t->content_is('alive');

my $systems17_raw = Mojo::Asset::File->new(path => "$FindBin::Bin/systems17.raw");

$t->post_ok('/systems/systems17test' => {Accept=>'*/*'} => form => {data=>$systems17_raw->slurp});
$t->get_ok('/systems.xml')->status_is(200);

my $xml_string = $t->tx->res->body;
my $xml = XML::Simple::Minded->new($xml_string);
isa_ok($xml,'XML::Simple::Minded');

done_testing();
