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

# Test 4: Case sensitivity - keys are stored as-is
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
ok($sam3->get_register('030d'), 'initialize_defaults creates 030d');
ok($sam3->get_register('3b02'), 'initialize_defaults creates 3b02');
ok($sam3->get_register('3b03'), 'initialize_defaults creates 3b03');

# Test 7: initialize_defaults() is idempotent
$sam3->initialize_defaults();
my $regs_before = $sam3->store->get('registers');
$sam3->initialize_defaults();
my $regs_after = $sam3->store->get('registers');
is_deeply($regs_before, $regs_after, 'initialize_defaults is idempotent');

# Test 8: notify_change writes to thermostat via bus
subtest 'notify_change sends bus write' => sub {
    {
        package MockBusWithTracking;
        use Moo;
        has writes => (is => 'rw', default => sub { [] });
        sub write_register {
            my ($self, $dst, $table, $row, $value, $opt) = @_;
            push @{$self->writes}, {
                dst => $dst, table => $table, row => $row, value => $value
            };
        }
    }

    my $td = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithTracking->new;
    my $sam = CarBus::SAM->new(
        bus    => $mock_bus,
        store  => CHI->new(driver => 'File', root_dir => $td),
    );
    $sam->initialize_defaults();

    $sam->notify_change('3b03');

    is(scalar(@{$mock_bus->writes}), 1, 'notify_change writes once to bus');
    is($mock_bus->writes->[0]{dst}, 'Thermostat', 'write destination is Thermostat');
    is($mock_bus->writes->[0]{table}, 0x3B, 'table byte correct');
    is($mock_bus->writes->[0]{row}, 0x03, 'row byte correct');

    my $log = $sam->activity_log;
    my @notifs = grep { $_->{action} eq 'notify_change' } @$log;
    is(scalar(@notifs), 1, 'notify_change logged');
    is($notifs[0]->{register}, '3b03', 'register logged');
};

# Test 9: 0420 is NOT initialized by initialize_defaults
subtest '0420 not in initialized registers' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $sam = CarBus::SAM->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $sam->initialize_defaults();

    is($sam->get_register('0420'), undef, '0420 not initialized');
    my $parser = CarBus::Frame::subparser('0420');
    ok($parser, '0420 parser still registered for frame decoding');
};

# Test 10: activity_log tracking
subtest 'activity_log tracking' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithTracking->new;
    my $sam = CarBus::SAM->new(
        bus    => $mock_bus,
        store  => CHI->new(driver => 'File', root_dir => $td),
    );
    $sam->initialize_defaults();

    is_deeply($sam->activity_log, [], 'activity_log starts empty');

    $sam->notify_change('3b06');
    $sam->notify_change('3b03');

    is(scalar(@{$sam->activity_log}), 2, 'two entries after two notifications');
    is($sam->activity_log->[0]{register}, '3b06', 'first notification is 3b06');
    is($sam->activity_log->[1]{register}, '3b03', 'second notification is 3b03');
};

# Test 11: emulated_src attribute
subtest 'emulated_src defaults to FakeSAM' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithTracking->new;
    my $sam = CarBus::SAM->new(
        bus   => $mock_bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    is($sam->emulated_src, 'FakeSAM', 'default emulated_src is FakeSAM');
};

subtest 'emulated_src configurable for real emulation' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithTracking->new;
    my $sam = CarBus::SAM->new(
        bus          => $mock_bus,
        store        => CHI->new(driver => 'File', root_dir => $td),
        emulated_src => 'SAM',
    );
    is($sam->emulated_src, 'SAM', 'emulated_src set to SAM');
    $sam->initialize_defaults();

    # Read reply should use SAM as source
    my $read_frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );
    my $reply = $sam->handle_frame($read_frame);
    $reply->frame;
    is($reply->struct->{src}, 'SAM', 'reply src is SAM when emulated_src is SAM');
};

# Test 13: set_zone_setpoint domain method
subtest 'set_zone_setpoint' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithTracking->new;
    my $sam = CarBus::SAM->new(
        bus    => $mock_bus,
        store  => CHI->new(driver => 'File', root_dir => $td),
    );
    $sam->initialize_defaults();

    # Get current zone 1 setpoints from initialized data
    my $zones_parser = CarBus::Frame::subparser('3B03');
    my $old_data = $sam->get_register('3b03');
    my $old_parsed = $zones_parser->parse($old_data);
    is($old_parsed->{heat_setpoint}[0], 68, 'initial heat setpoint is 68');
    is($old_parsed->{cool_setpoint}[0], 76, 'initial cool setpoint is 76');

    # Set new setpoints for zone 1
    $sam->set_zone_setpoint(1, 70, 74);

    # Verify internal state updated
    my $new_data = $sam->get_register('3b03');
    my $new_parsed = $zones_parser->parse($new_data);
    is($new_parsed->{heat_setpoint}[0], 70, 'heat setpoint updated to 70');
    is($new_parsed->{cool_setpoint}[0], 74, 'cool setpoint updated to 74');

    # Other zones unchanged
    is($new_parsed->{heat_setpoint}[1], 68, 'zone 2 heat setpoint unchanged');

    # Verify bus write happened
    is(scalar(@{$mock_bus->writes}), 1, 'one bus write issued');
    is($mock_bus->writes->[0]{dst}, 'Thermostat', 'write to Thermostat');
    is($mock_bus->writes->[0]{table}, 0x3B, 'table is 3B');
    is($mock_bus->writes->[0]{row}, 0x03, 'row is 03');
};

done_testing();
