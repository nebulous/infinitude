use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use CarBus::SAM;
use CHI;

# Use a temp directory for test storage
my $tempdir = tempdir(CLEANUP => 1);

# Create a mock bus object (minimal, just for testing)
{
    package MockBus;
    use Moo;
}

my $bus = MockBus->new;

# Test 1: Create SAM with custom store
my $sam = CarBus::SAM->new(
    bus => $bus,
    store => CHI->new(driver => 'File', root_dir => $tempdir),
);

ok($sam, 'SAM object created');
isa_ok($sam->store, 'CHI::Driver::File');

# Test 2: registers() returns empty hash initially
my $regs = $sam->registers;
is(ref($regs), 'HASH', 'registers() returns hash');
is(scalar(keys %$regs), 0, 'registers() empty initially');

# Test 3: set_register() and get_register()
my $test_data = "test binary data\x00\x01\x02";
$sam->set_register('TEST', $test_data);
is($sam->get_register('TEST'), $test_data, 'set_register/get_register roundtrip');

# Test 4: Case sensitivity
$sam->set_register('UPPER', 'upper_value');
is($sam->get_register('upper'), undef, 'get_register is case-sensitive');
is($sam->get_register('UPPER'), 'upper_value', 'get_register returns correct value');

# Test 5: Persistence - create new SAM with same store
my $sam2 = CarBus::SAM->new(
    bus => $bus,
    store => CHI->new(driver => 'File', root_dir => $tempdir),
);
is($sam2->get_register('TEST'), $test_data, 'register persists across instances');

# Test 6: initialize_defaults() creates expected registers
my $tempdir2 = tempdir(CLEANUP => 1);
my $sam3 = CarBus::SAM->new(
    bus => $bus,
    store => CHI->new(driver => 'File', root_dir => $tempdir2),
);
$sam3->initialize_defaults();

ok($sam3->get_register('0104'), 'initialize_defaults creates 0104');
ok($sam3->get_register('030D'), 'initialize_defaults creates 030D');
ok($sam3->get_register('3B02'), 'initialize_defaults creates 3B02');
ok($sam3->get_register('3B03'), 'initialize_defaults creates 3B03');

# Test 7: initialize_defaults() is idempotent
$sam3->initialize_defaults();
my $regs_before = $sam3->store->get('registers');
$sam3->initialize_defaults();
my $regs_after = $sam3->store->get('registers');
is_deeply($regs_before, $regs_after, 'initialize_defaults is idempotent');

done_testing();
