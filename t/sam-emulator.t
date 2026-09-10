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
        sub write {
            my ($self, $frame) = @_;
            push @{$self->writes}, $frame;
        }
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
    my $write_frame = $mock_bus->writes->[0];
    $write_frame->frame;  # finalize
    is($write_frame->struct->{dst}, 'Thermostat', 'write to Thermostat');
    is($write_frame->struct->{reg_string}, '3b03', 'register is 3b03');
};

# Test 14: set_zone_hold encoding (0x82 timed, 0x02 permanent/cancel)
subtest 'set_zone_hold encoding' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithTracking->new;
    my $sam = CarBus::SAM->new(
        bus    => $mock_bus,
        store  => CHI->new(driver => 'File', root_dir => $td),
    );
    $sam->initialize_defaults();

    my $parser = CarBus::Frame::subparser('3B03');
    my $decode = sub {
        my ($frame) = @_;
        $frame->frame;  # finalize struct
        return $parser->parse(substr($frame->struct->{payload_raw}, 3));
    };

    # Timed hold, zone 3, duration already on the grid
    ok($sam->set_zone_hold(3, 120), 'timed hold returns true');
    my $p = $decode->($mock_bus->writes->[0]);
    is($p->{change_flags}{hold}, 1, 'timed: change flag 0x02 (hold) set');
    is($p->{change_flags}{override_timer}, 1, 'timed: change flag 0x80 (override_timer) set');
    is($p->{zones_holding}{z3}, 0, 'timed: zones_holding bit clear');
    is($p->{hold_duration}[2], 120, 'timed: duration 120 minutes');
    is($p->{zones_timed}{z3}, 0, 'timed: zones_timed left alone (tstat owns it)');
    is($p->{active_zones}, 2, 'timed: write header zone index zero-based (3 -> 2)');

    # Normalization onto the 15-minute grid, clamped to [15, 1425]
    $sam->set_zone_hold(1, 5);     # sub-floor: rounds to 0, clamped up to 15
    is($decode->($mock_bus->writes->[1])->{hold_duration}[0], 15, 'floor: 5 -> 15');
    $sam->set_zone_hold(1, 23);    # rounds to nearest 15
    is($decode->($mock_bus->writes->[2])->{hold_duration}[0], 30, 'round: 23 -> 30');
    $sam->set_zone_hold(1, 1439);  # over documented max: clamped to 1425
    is($decode->($mock_bus->writes->[3])->{hold_duration}[0], 1425, 'clamp: 1439 -> 1425');

    # Permanent hold, zone 3
    ok($sam->set_zone_hold(3, 65535), 'permanent hold returns true');
    my $pp = $decode->($mock_bus->writes->[4]);
    is($pp->{change_flags}{hold}, 1, 'permanent: change flag 0x02 (hold) set');
    is($pp->{change_flags}{override_timer}, 0, 'permanent: no timer flag');
    is($pp->{zones_holding}{z3}, 1, 'permanent: zone 3 zones_holding bit set');
    is($pp->{hold_duration}[2], 0, 'permanent: duration written as 0 (tstat adopts 0xFFFF)');

    # Cancel
    ok($sam->set_zone_hold(3, 0), 'cancel returns true');
    my $pc = $decode->($mock_bus->writes->[5]);
    is($pc->{change_flags}{hold}, 1, 'cancel: uses flag 0x02');
    is($pc->{zones_holding}{z3}, 0, 'cancel: zone 3 bit cleared');
    is($pc->{hold_duration}[2], 0, 'cancel: duration 0');

    # Cache coherence: the served register mirrors the last written state
    my $cached = $parser->parse($sam->get_register('3b03'));
    is($cached->{zones_holding}{z3}, 0, 'cached zones_holding bit cleared');
    is($cached->{hold_duration}[0], 1425, 'cached duration mirrors last timed write');
    is($cached->{change_flags}{hold}, 0, 'cached change flags reset to read format');

    # Zone bounds guard
    is($sam->set_zone_hold(9, 65535), undef, 'zone 9 rejected');
    is(scalar(@{$mock_bus->writes}), 6, 'no frame sent for out-of-range zone');
};

# Test 15: stagmode mode values (corroborated by infinitive conversions.go
# and InfinitESP infinitesp.h: 4=heatpump, 5=off; the old map had 4=off)
subtest 'stagmode mode values' => sub {
    my $p = CarBus::Frame::subparser('3B02');

    # Build side: each mode name writes its nibble
    my %expect = (heat => 0, cool => 1, auto => 2, eheat => 3, heatpump => 4, off => 5);
    for my $mode (sort keys %expect) {
        my $bytes = $p->build({
            active_zones => 0x01, metric_units => 'english',
            temperature => [(70) x 8], humidity => [(50) x 8], oat => 70,
            zones_unoccupied => { map { ("z$_" => 0) } 1..8 },
            stagmode => { stage => 0, mode => $mode }, unknown => [0, 0],
            weekday => 'Monday', minutes_since_midnight => 480, displayed_zone => 1,
        });
        is(ord(substr($bytes, 22, 1)) & 0x0F, $expect{$mode}, "build $mode -> nibble $expect{$mode}");
    }

    # Parse side: each nibble decodes to its mode name
    my $bytes = $p->build({
        active_zones => 0x01, metric_units => 'english',
        temperature => [(70) x 8], humidity => [(50) x 8], oat => 70,
        zones_unoccupied => { map { ("z$_" => 0) } 1..8 },
        stagmode => { stage => 0, mode => 'heat' }, unknown => [0, 0],
        weekday => 'Monday', minutes_since_midnight => 480, displayed_zone => 1,
    });
    for my $v (0..5) {
        substr($bytes, 22, 1) = chr($v);
        my $name = { reverse %expect }->{$v};
        is($p->parse($bytes)->{stagmode}{mode}, $name, "nibble $v -> $name");
    }
};

# Test 16: set_system_mode writes the corrected mode nibble with flag 0x10
subtest 'set_system_mode encoding' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithTracking->new;
    my $sam = CarBus::SAM->new(
        bus    => $mock_bus,
        store  => CHI->new(driver => 'File', root_dir => $td),
    );
    $sam->initialize_defaults();

    ok($sam->set_system_mode('off'), 'set_system_mode returns true');
    my $frame = $mock_bus->writes->[0];
    $frame->frame;
    my $data = substr($frame->struct->{payload_raw}, 3);
    is(ord(substr($data, 2, 1)), 0x10, 'write header carries flag 0x10');
    is(ord(substr($data, 22, 1)) & 0x0F, 5, 'off writes mode nibble 5 (was 4)');

    my $cached = CarBus::Frame::subparser('3B02')->parse($sam->get_register('3b02'));
    is($cached->{stagmode}{mode}, 'off', 'cached 3B02 mode is off');
};

done_testing();
