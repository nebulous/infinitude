use strict;
use warnings;
use feature ':5.10';
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Path::Tiny;
use Cwd;

# PASS_REQS=0 must disable passthrough even when infinitude.json says otherwise
my $dir = Path::Tiny->tempdir;
$dir->child('infinitude.json')->spew('{"app_secret":"testing","pass_reqs":300}');
my $orig_cwd = getcwd;
chdir $dir;

local $ENV{PASS_REQS} = '0';
require "$FindBin::Bin/../infinitude";

{ no warnings 'once';
is($main::config->{pass_reqs}, 0, 'PASS_REQS=0 overrides pass_reqs from infinitude.json');
}

chdir $orig_cwd;
done_testing();
