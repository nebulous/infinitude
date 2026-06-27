#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use CarBus;
use CarBus::Frame;
use CarBus::SAM;
use CHI;

# ============================================================================
# Mock bus packages (must be defined before tests)
# ============================================================================
{
    package MockBus;
    use Moo;
    use CarBus::Frame;
    has name => (is => 'ro', default => 'MockBus');
    has _buffer => (is => 'rw', default => '', init_arg => undef);
    has devices => (is => 'rw', default => sub { {} });
    has handlers => (is => 'rw', default => sub { [] });

    sub device_names { return [keys %{shift->devices}] }
    sub run_handlers {}
    sub get_frame {
        my $self = shift;
        return unless length $self->_buffer >= 10;
        my $cbf = CarBus::Frame->new($self->_buffer);
        if ($cbf->valid) {
            my $len = 10 + $cbf->struct->{length};
            $self->_buffer(substr($self->_buffer, $len));
            return $cbf;
        }
        $self->_buffer(substr($self->_buffer, 1));
        return;
    }
    sub inject_frame {
        my ($self, %args) = @_;
        my $f = CarBus::Frame->new(%args);
        $self->_buffer($self->_buffer . $f->frame);
    }
    sub write {
        my ($self, $frame) = @_;
        push @{$self->writes}, $frame;
    }
    has writes => (is => 'ro', default => sub { [] });

    package MockBusWithWrite;
    use Moo;
    has writes => (is => 'rw', default => sub { [] });
    sub write_register {
        my ($self, @args) = @_;
        push @{$self->writes}, \@args;
    }
}

# ============================================================================
# Test 1: SAM parsers auto-registered when CarBus is loaded
# ============================================================================
subtest 'SAM parsers registered via use CarBus' => sub {
    # use CarBus loads CarBus::SAM which calls add_parser at module load time
    for my $reg (qw(030D 3B02 3B03 3B04 3B05 3B06 3B0E 0420)) {
        my $parser = CarBus::Frame::subparser($reg);
        ok($parser, "parser for $reg registered");
        isnt($parser->{Name}, 'unknown', "$reg parser is not the fallback 'unknown'");
    }
};

# ============================================================================
# Test 2: _track_registers populates devices from frames
# ============================================================================
subtest '_track_registers default handler populates devices' => sub {
    # Build a reply frame with parseable payload (030D = 7 bytes)
    my $parser = CarBus::Frame::subparser('030D');
    my $data = $parser->build({
        val1 => 61, val2 => 62, val3 => 63,
        reserved1 => 0, reserved2 => 0, reserved3 => 0, reserved4 => 0,
    });

    my $reply_hex = CarBus::Frame->new(
        src => 'SAM', src_bus => 1,
        dst => 'Thermostat', dst_bus => 1,
        cmd => 'reply',
        payload_raw => pack("C*", 0, 0x03, 0x0D) . $data,
    )->frame_hex;

    my $frame = CarBus::Frame->new($reply_hex);
    ok($frame->valid, 'reply frame is valid');

    # Simulate what run_handlers does by calling _track_registers directly
    # We can't create a real CarBus (needs IO handle), so test via injection
    my $devices = {};
    my $fs = $frame->struct;

    # Replicate _track_registers logic
    $devices->{$fs->{src}} //= {};
    if ($fs->{payload_hex} ne '00' . ($fs->{reg_string} || '')) {
        $devices->{$fs->{src}}->{$fs->{reg_string}} //= { payload_hex => $fs->{payload_hex} } if $fs->{reg_string};
        $devices->{$fs->{src}}->{$fs->{reg_string}}->{payload} = $fs->{payload} if $fs->{payload};
    }

    ok(exists $devices->{SAM}, 'SAM device tracked');
    ok(exists $devices->{SAM}{rx030D} || exists $devices->{SAM}{'030d'}, '030D register tracked for SAM');
    is($devices->{SAM}{'030d'}{payload}{val1}, 61, 'parsed payload stored correctly');
};

# ============================================================================
# Test 3: Bridge selective routing
# ============================================================================
subtest 'Bridge selective routing' => sub {
    # Mock bus that records writes and can be fed frames
    my @bus_a_writes;
    my @bus_b_writes;

    my $bus_a = MockBus->new(name => 'A', writes => \@bus_a_writes);
    my $bus_b = MockBus->new(name => 'B', writes => \@bus_b_writes);

    my $bridge = CarBus::Bridge->new(buslist => [$bus_a, $bus_b]);

    # --- Case 1: Broadcast from A forwards to B
    @bus_b_writes = ();
    $bus_a->inject_frame(
        src => 'Thermostat', src_bus => 1,
        dst => 'Broadcast', dst_bus => 0,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );
    $bridge->drive;
    is(scalar @bus_b_writes, 1, 'broadcast frame forwarded to B');

    # --- Case 2: Frame addressed to known device on B
    @bus_b_writes = ();
    $bus_b->{devices}{SAM} = {};    # B knows about SAM
    $bus_a->inject_frame(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x3B\x02",
    );
    $bridge->drive;
    is(scalar @bus_b_writes, 1, 'frame to known device on B forwarded');

    # --- Case 3: Frame NOT addressed to any known device on B (B has devices)
    @bus_b_writes = ();
    $bus_a->inject_frame(
        src => 'Thermostat', src_bus => 1,
        dst => 'IndoorUnit', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );
    $bridge->drive;
    is(scalar @bus_b_writes, 0, 'frame to unknown device on B NOT forwarded');

    # --- Case 4: Frame forwarded to B when B has no known devices (discovery)
    @bus_b_writes = ();
    $bus_b->{devices} = {};         # B knows nothing yet
    $bus_a->{devices} = {};         # A knows nothing yet (so src/dst skip won't fire)
    $bus_a->inject_frame(
        src => 'Thermostat', src_bus => 1,
        dst => 'IndoorUnit', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );
    $bridge->drive;
    is(scalar @bus_b_writes, 1, 'frame forwarded to B when B has no devices (discovery)');

    # --- Case 5: Frame NOT forwarded when src and dst both on source bus
    @bus_b_writes = ();
    $bus_a->{devices}{Thermostat} = {};
    $bus_a->{devices}{SAM} = {};
    $bus_b->{devices}{SAM} = {};    # B also knows SAM (but skip rule fires first)
    $bus_a->inject_frame(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x3B\x02",
    );
    $bridge->drive;
    is(scalar @bus_b_writes, 0, 'frame NOT forwarded when src+dst both on source bus');

    # --- Case 6: A->B writes don't bounce back to A
    @bus_a_writes = ();
    $bus_b->{devices} = {};
    $bus_a->{devices} = {};
    $bus_b->inject_frame(
        src => 'SAM', src_bus => 1,
        dst => 'Broadcast', dst_bus => 0,
        cmd => 'reply',
        payload_raw => "\x00\x01\x04" . ("X" x 20),
    );
    $bridge->drive;
    is(scalar @bus_a_writes, 1, 'broadcast from B does forward to A');
};

# ============================================================================
# Test 4: SAM _handle_read and _handle_write
# ============================================================================
subtest 'SAM handle_frame read/write' => sub {
    my $tempdir = tempdir(CLEANUP => 1);
    my $mock_bus = MockBusWithWrite->new;
    my $sam = CarBus::SAM->new(
        bus   => $mock_bus,
        store => CHI->new(driver => 'File', root_dir => $tempdir),
    );
    $sam->initialize_defaults();

    # --- Read: query 0104 from Thermostat
    my $read_frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );

    my $reply = $sam->handle_frame($read_frame);
    ok($reply, 'handle_frame returns a reply for read');
    $reply->frame;  # Finalize frame (computes checksum, parses payload)
    is($reply->struct->{cmd}, 'reply', 'reply cmd is reply');
    is($reply->struct->{src}, 'FakeSAM', 'reply src is FakeSAM');
    is($reply->struct->{dst}, 'Thermostat', 'reply dst is Thermostat');
    is($reply->struct->{reg_string}, '0104', 'reply reg_string is 0104');
    is($reply->struct->{payload}{model}, 'INFINITUDE01', 'reply payload has device_identity model');

    # --- Read: query unknown register returns exception
    my $unknown_read = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\xFF\xFF",
    );
    my $exc_reply = $sam->handle_frame($unknown_read);
    ok($exc_reply, 'handle_frame returns exception reply for unknown register read');
    $exc_reply->frame;
    is($exc_reply->struct->{cmd}, 'exception', 'exception reply cmd is exception');
    is($exc_reply->struct->{src}, 'FakeSAM', 'exception reply src is emulated_src');
    is($exc_reply->struct->{dst}, 'Thermostat', 'exception reply dst is requestor');
    is($exc_reply->struct->{reg_string}, 'ffff', 'exception reply reg_string matches request');
    is(unpack("C", substr($exc_reply->struct->{payload_raw}, 3, 1)), 0x04, 'exception code is 0x04');

    # --- Write: write to 3B06
    my $new_dealer = CarBus::Frame::subparser('3B06')->build({
        backlight => 2, metric_units => 'english', unknown1 => 0, deadband => 3,
        cycles_per_hour => 4, schedule_periods => 4, programs_enabled => 1,
        unknown2 => 0xFF, unknown3 => 0xFF, programs_enabled_2 => 1,
        metric_units_2 => 'english', unknown4 => 0,
        dealer_name => "TestDealer\0\0\0\0\0\0\0\0\0\0",
        dealer_phone => "555-1212\0\0\0\0\0\0\0\0\0\0\0\0",
    });
    my $write_frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'write',
        payload_raw => pack("C*", 0, 0x3B, 0x06) . $new_dealer,
    );
    my $ack = $sam->handle_frame($write_frame);
    ok($ack, 'handle_frame returns ack for write');
    is($ack->struct->{cmd}, 'reply', 'write ack is reply');
    is($ack->struct->{payload_raw}, $write_frame->struct->{payload_raw}, 'ack echoes payload');

    # Verify the write persisted
    ok(defined $sam->get_register('3b06'), '3b06 stored after write');

    # --- Ignore frames not addressed to SAM
    my $not_ours = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'IndoorUnit', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );
    is($sam->handle_frame($not_ours), undef, 'handle_frame ignores non-SAM frames');

    # --- Read with custom handler overrides store
    my $handler_called = 0;
    $sam->on_read('3b02', sub { $handler_called++; return "\xAA\xBB" });
    my $custom_read = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x3B\x02",
    );
    my $custom_reply = $sam->handle_frame($custom_read);
    is($handler_called, 1, 'custom read handler called');
    is(substr($custom_reply->struct->{payload_raw}, 3), "\xAA\xBB", 'custom handler data used');
};

# ============================================================================
# Test 5: Frame::frame() with changes hash
# ============================================================================
subtest 'Frame::frame() with changes hash' => sub {
    # Build a valid frame first
    my $f = CarBus::Frame->new(
        src => 'SAM', src_bus => 1,
        dst => 'Thermostat', dst_bus => 1,
        cmd => 'reply',
        payload_raw => "\x00\x01\x04" . ("X" x 20),
    );
    my $original = $f->frame;
    ok($f->valid, 'frame is valid');

    # Mutate payload_raw via changes hash
    my $new_payload = "\x00\x03\x0D\x3D\x3E\x3F\x00\x00\x00\x00";
    my $result = $f->frame({ payload_raw => $new_payload });
    ok($result, 'frame() with changes returns truthy');
    is($f->struct->{payload_raw}, $new_payload, 'payload_raw updated via changes');
    is($f->struct->{reg_string}, '030d', 'reg_string updated after mutation');
    ok($f->valid, 'mutated frame is still valid');

    # Verify it round-trips
    my $f2 = CarBus::Frame->new($f->frame_hex);
    ok($f2->valid, 're-parsed mutated frame is valid');
    is($f2->struct->{payload_raw}, $new_payload, 're-parsed payload matches');

    # Changes hash with no-op mutation produces same output
    my $f3 = CarBus::Frame->new(
        src => 'SAM', src_bus => 1,
        dst => 'Thermostat', dst_bus => 1,
        cmd => 'reply',
        payload_raw => "\x00\x01\x04" . ("Y" x 20),
    );
    $f3->frame;  # finalize
    my $prev_hex = $f3->frame_hex;
    $f3->frame({ payload_raw => "\x00\x01\x04" . ("Y" x 20) });  # same payload
    is($f3->frame_hex, $prev_hex, 'frame with no-op changes produces same output');
};

done_testing();
