use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

require_ok('CHI');
require_ok('DateTime');
require_ok('Hash::AsObject');
require_ok('IO::File');
require_ok('JSON');
require_ok('Moo');
require_ok('Mojolicious::Lite');
require_ok('Mojo::JSON');
require_ok('Path::Tiny');
require_ok('Try::Tiny');
require_ok('Time::HiRes');
require_ok('WWW::Wunderground::API');
require_ok('XML::Simple');
require_ok('XML::Simple::Minded');

done_testing();
