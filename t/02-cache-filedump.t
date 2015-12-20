use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More; # tests=>9;

BEGIN {
	use_ok('Cache::FileDump');
}

my $store = Cache::FileDump->new(base=>'t/test_store', default_expires_in=>1);
isa_ok($store, 'Cache::FileDump');

$store->set('cow','moo');
$store->set('boo','who?',3);
is($store->get('cow'),'moo','the cow says moo');
is($store->get('cow'),'moo','the cow still says moo');

my $one = { one=>1, won=>'the fight', juan=>[1,2,3,4] };
$store->set('one', $one);
is_deeply($one, $store->get('one'), 'default serializers go');
is($store->get('boo'),'who?','the boo says who?');
is($store->get('boo'),'who?','the boo still says who?');
sleep 2;
isnt($store->get('cow'),'moo','the cow no longer says moo');
is($store->get('boo'),'who?','the boo still says who?');
sleep 2;
isnt($store->get('boo'),'who?','the boo no longer says who?');

done_testing();
