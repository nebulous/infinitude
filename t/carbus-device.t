#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use CHI;
use lib 'lib';

# Load Frame first (parsers registered at load time)
use CarBus::Frame;
use CarBus::Device;
use CarBus::ZoneController;

# --- Mock bus for testing ---
{
    package MockBus;
    use Moo;
    has written => (is => 'rw', default => sub { [] });
    sub write {
        my ($self, $frame) = @_;
        $frame->frame;
        push @{$self->written}, $frame;
    }
    sub read_register {
        my ($self, $dst, $table, $row, $opt) = @_;
        $opt //= {};
        my $frame = CarBus::Frame->new(
            src     => $opt->{src} // 'FakeSAM',
            src_bus => $opt->{src_bus} // 1,
            dst     => $dst,
            dst_bus => $opt->{dst_bus} // 1,
            cmd     => 'read',
            payload_raw => pack("C*", 0, $table, $row),
        );
        $self->write($frame);
        return $frame;
    }
    sub write_register {
        my ($self, $dst, $table, $row, $value, $opt) = @_;
        $opt //= {};
        my $frame = CarBus::Frame->new(
            src     => $opt->{src} // 'FakeSAM',
            src_bus => $opt->{src_bus} // 1,
            dst     => $dst,
            dst_bus => $opt->{dst_bus} // 1,
            cmd     => 'write',
            payload_raw => pack("C*", 0, $table, $row) . $value,
        );
        $self->write($frame);
        return $frame;
    }
}

# ========== Device base class ==========

subtest 'Device: register storage' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $dev = CarBus::Device->new(
        bus     => $bus,
        src_name => 'ZoneControl',
        store   => CHI->new(driver => 'File', root_dir => $td),
    );

    is_deeply($dev->registers, {}, 'registers empty initially');
    ok(!defined $dev->get_register('0302'), 'get_register returns undef for unknown');

    $dev->set_register('0302', "hello");
    is($dev->get_register('0302'), 'hello', 'set/get roundtrip');
    is_deeply($dev->known_registers, ['0302'], 'known_registers lists keys');

    # learn_register on a NEW key (different register)
    ok($dev->learn_register('030d', "learned"), 'learn_register returns true for new register');
    is($dev->get_register('030d'), 'learned', 'learn_register stores value');

    # learn_register on existing key does not overwrite
    ok(!$dev->learn_register('030d', "again"), 'learn_register returns false for existing');
    is($dev->get_register('030d'), 'learned', 'learn_register does not overwrite');
};

subtest 'Device: handle_frame ignores non-matching dst' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $dev = CarBus::Device->new(
        bus      => $bus,
        src_name => 'ZoneControl',
        store    => CHI->new(driver => 'File', root_dir => $td),
    );

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,   # Not ZoneControl
        cmd => 'read',
        payload_raw => "\x00\x03\x02",
    );
    my $reply = $dev->handle_frame($frame);
    ok(!defined $reply, 'handle_frame returns undef for non-matching dst');
};

subtest 'Device: handle_frame read (known register)' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $dev = CarBus::Device->new(
        bus      => $bus,
        src_name => 'ZoneControl',
        store    => CHI->new(driver => 'File', root_dir => $td),
    );
    $dev->set_register('0302', pack("C*", 0xAA, 0xBB));

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x03\x02",
    );
    my $reply = $dev->handle_frame($frame);
    ok(defined $reply, 'handle_frame returns reply for known register');
    $reply->frame;
    is($reply->struct->{cmd}, 'reply', 'reply cmd is reply');
    is($reply->struct->{src}, 'ZoneControl', 'reply src is device src_name');
    is($reply->struct->{dst}, 'Thermostat', 'reply dst is requestor');
    is($reply->struct->{reg_string}, '0302', 'reply reg_string correct');
    # payload after 3-byte register prefix should be our stored data
    is(substr($reply->struct->{payload_raw}, 3), pack("C*", 0xAA, 0xBB),
       'reply payload contains register data');
};

subtest 'Device: handle_frame read (unknown register → exception)' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $dev = CarBus::Device->new(
        bus      => $bus,
        src_name => 'ZoneControl',
        store    => CHI->new(driver => 'File', root_dir => $td),
    );

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\xFF\xFF",
    );
    my $reply = $dev->handle_frame($frame);
    ok(defined $reply, 'handle_frame returns exception reply');
    $reply->frame;
    is($reply->struct->{cmd}, 'exception', 'exception cmd');
    is($reply->struct->{src}, 'ZoneControl', 'exception src is device src_name');
};

subtest 'Device: handle_frame write (stores and ACKs)' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $dev = CarBus::Device->new(
        bus      => $bus,
        src_name => 'ZoneControl',
        store    => CHI->new(driver => 'File', root_dir => $td),
    );

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'write',
        payload_raw => "\x00\x34\x04" . pack("C", 0x42),
    );
    my $reply = $dev->handle_frame($frame);
    ok(defined $reply, 'handle_frame returns ACK for write');
    $reply->frame;
    is($reply->struct->{cmd}, 'reply', 'ACK is reply');
    is($reply->struct->{payload_raw}, $frame->struct->{payload_raw},
       'ACK echoes payload');

    is($dev->get_register('3404'), pack("C", 0x42), 'write stored in register');
};

subtest 'Device: on_read/on_write callbacks' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $dev = CarBus::Device->new(
        bus      => $bus,
        src_name => 'ZoneControl',
        store    => CHI->new(driver => 'File', root_dir => $td),
    );

    my $read_data;
    $dev->on_read('0302', sub { $read_data = pack("C*", 0x11, 0x22); return $read_data; });

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x03\x02",
    );
    my $reply = $dev->handle_frame($frame);
    $reply->frame;
    is(substr($reply->struct->{payload_raw}, 3), pack("C*", 0x11, 0x22),
       'on_read handler data used in reply');

    my $written_value;
    $dev->on_write('3404', sub { $written_value = shift; });
    my $wframe = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'write',
        payload_raw => "\x00\x34\x04" . pack("C", 0x99),
    );
    $dev->handle_frame($wframe);
    is($written_value, pack("C", 0x99), 'on_write handler received value');
};

subtest 'Device: read_device/write_device convenience' => sub {
    my $bus = MockBus->new;
    my $dev = CarBus::Device->new(
        bus      => $bus,
        src_name => 'ZoneControl',
    );

    $dev->read_device('Thermostat', 0x01, 0x04);
    is(scalar @{$bus->written}, 1, 'read_device writes one frame');
    my $rf = $bus->written->[0];
    $rf->frame;
    is($rf->struct->{src}, 'ZoneControl', 'read src is device');
    is($rf->struct->{dst}, 'Thermostat', 'read dst correct');
    is($rf->struct->{cmd}, 'read', 'cmd is read');

    $bus->written([]);
    $dev->write_device('Thermostat', 0x3B, 0x03, "data");
    is(scalar @{$bus->written}, 1, 'write_device writes one frame');
    my $wf = $bus->written->[0];
    $wf->frame;
    is($wf->struct->{src}, 'ZoneControl', 'write src is device');
    is($wf->struct->{dst}, 'Thermostat', 'write dst correct');
    is($wf->struct->{cmd}, 'write', 'cmd is write');
};

subtest 'Device: per-device store directory' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;

    my $dev1 = CarBus::Device->new(
        bus      => $bus,
        src_name => 'ZoneControl',
        store    => CHI->new(driver => 'File', root_dir => "$td/zc"),
    );
    my $dev2 = CarBus::Device->new(
        bus      => $bus,
        src_name => 'FakeSAM',
        store    => CHI->new(driver => 'File', root_dir => "$td/sam"),
    );

    $dev1->set_register('0302', "from_zc");
    $dev2->set_register('0302', "from_sam");

    is($dev1->get_register('0302'), 'from_zc', 'ZC register independent');
    is($dev2->get_register('0302'), 'from_sam', 'SAM register independent');
};

# ========== ZoneController ==========

subtest 'ZoneController: initialize_defaults' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    ok(defined $zc->get_register('0104'), '0104 initialized');
    ok(defined $zc->get_register('0302'), '0302 initialized');
    ok(defined $zc->get_register('0319'), '0319 initialized');
    ok(defined $zc->get_register('030d'), '030d initialized');
    ok(defined $zc->get_register('3404'), '3404 initialized');

    # Check 0104 device info parses
    my $info_parser = CarBus::Frame::subparser('0104');
    my $info = $info_parser->parse($zc->get_register('0104'));
    is($info->{model}, 'SYSTXCC4ZC01', 'device_info model correct');
    is($info->{software}, 'INFD-ZC-01', 'device_info software correct');

    # Check 0302 is 24 bytes
    is(length($zc->get_register('0302')), 24, '0302 is 24 bytes');

    # Check 0319 is 8 bytes
    is(length($zc->get_register('0319')), 8, '0319 is 8 bytes');

    # Check 030d is 7 zero bytes
    is($zc->get_register('030d'), "\x00" x 7, '030d is 7 zeros');
};

subtest 'ZoneController: initialize_defaults is idempotent' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    # Manually modify a register
    $zc->set_register('0302', "modified");
    $zc->initialize_defaults();    # Should NOT overwrite
    is($zc->get_register('0302'), 'modified', 'second initialize_defaults does not overwrite');
};

subtest 'ZoneController: handle_frame read 0104' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );
    my $reply = $zc->handle_frame($frame);
    ok(defined $reply, 'got reply for 0104 read');
    $reply->frame;
    is($reply->struct->{valid}, 1, 'reply is valid');
    is($reply->struct->{src}, 'ZoneControl', 'reply src is ZoneControl');
    is($reply->struct->{cmd}, 'reply', 'reply cmd is reply');
    is($reply->struct->{reg_string}, '0104', 'reg_string is 0104');
    # 3 byte prefix + 120 bytes device_info
    is(length($reply->struct->{payload_raw}), 123, 'reply payload is 123 bytes');
};

subtest 'ZoneController: handle_frame read 0302' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x03\x02",
    );
    my $reply = $zc->handle_frame($frame);
    ok(defined $reply, 'got reply for 0302 read');
    $reply->frame;
    is(length($reply->struct->{payload_raw}), 27, 'reply payload is 27 bytes (3+24)');
};

subtest 'ZoneController: write/ACK cycle for 3404' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    # Thermostat writes 3404 = 0x00
    my $write_frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'write',
        payload_raw => "\x00\x34\x04\x00",
    );
    my $ack = $zc->handle_frame($write_frame);
    ok(defined $ack, 'ZC ACKs the write');
    $ack->frame;
    is($ack->struct->{cmd}, 'reply', 'ACK is reply');
    is($ack->struct->{src}, 'ZoneControl', 'ACK src is ZoneControl');

    # Subsequent read should return 0x00
    my $read_frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x34\x04",
    );
    my $reply = $zc->handle_frame($read_frame);
    ok(defined $reply, 'ZC responds to read after write');
    $reply->frame;
    is(substr($reply->struct->{payload_raw}, 3), pack("C", 0x00),
       'read returns written value');
};

subtest 'ZoneController: set_zone_reading' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    # Default zone 2 reading is 0x4E (78)
    my $parser = CarBus::Frame::subparser('0302', 'ZoneControl');
    my $parsed = $parser->parse($zc->get_register('0302'));
    is($parsed->{zone2}{value}, 0x4E, 'zone 2 starts at 78');

    $zc->set_zone_reading(2, 85);
    $parsed = $parser->parse($zc->get_register('0302'));
    is($parsed->{zone2}{value}, 85, 'zone 2 updated to 85');

    $zc->set_zone_reading(3, 72);
    $parsed = $parser->parse($zc->get_register('0302'));
    is($parsed->{zone3}{value}, 72, 'zone 3 updated to 72');

    $zc->set_zone_reading(4, 65);
    $parsed = $parser->parse($zc->get_register('0302'));
    is($parsed->{zone4}{value}, 65, 'zone 4 updated to 65');

    # Zone 1 is not allowed (no sensor)
    $zc->set_zone_reading(1, 80);
    $parsed = $parser->parse($zc->get_register('0302'));
    is($parsed->{zone2}{value}, 85,
       'zone 1 update rejected, zone 2 unchanged');
};

subtest 'ZoneController: ignores frames to other devices' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    my $frame = CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'SAM', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x01\x04",
    );
    my $reply = $zc->handle_frame($frame);
    ok(!defined $reply, 'ZC ignores frames addressed to SAM');
};

# ========== Device-scoped parser registry ==========

subtest 'Frame: device-scoped parser registry' => sub {
    # Register a parser scoped to ZoneControl
    use Data::ParseBinary;
    my $zc_parser = Struct('zc_test', Byte('value'));
    CarBus::Frame->add_device_parser('ZoneControl', 'ZZZZ', $zc_parser);

    # subparser with src='ZoneControl' should find it
    my $found = CarBus::Frame::subparser('ZZZZ', 'ZoneControl');
    ok($found, 'device-scoped parser found for ZoneControl');
    isnt($found->{Name}, 'unknown', 'device-scoped parser is not unknown');

    # subparser with different src should not find it
    my $not_found = CarBus::Frame::subparser('ZZZZ', 'FakeSAM');
    is($not_found->{Name}, 'unknown', 'device-scoped parser not found for FakeSAM');

    # subparser without src should not find it
    my $no_src = CarBus::Frame::subparser('ZZZZ');
    is($no_src->{Name}, 'unknown', 'device-scoped parser not found without src');

    # Global parsers still work when src is provided
    my $global = CarBus::Frame::subparser('0104', 'ZoneControl');
    ok($global, 'global parser 0104 found via fallback');
    isnt($global->{Name}, 'unknown', 'global parser is not unknown');

    # Clean up the test parser
    delete $CarBus::Frame::device_parsers{'ZoneControl'}{'ZZZZ'};
};

# ========== ZC parser round-trip tests ==========

subtest 'ZC parser: 0302 zone readings round-trip' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    my $raw = $zc->get_register('0302');
    is(length($raw), 24, '0302 raw data is 24 bytes');

    my $parser = CarBus::Frame::subparser('0302', 'ZoneControl');
    ok($parser, 'device-scoped 0302 parser found');
    isnt($parser->{Name}, 'unknown', 'parser is not unknown');

    my $parsed = $parser->parse($raw);
    is($parsed->{zone_count}, 4, 'zone_count is 4');
    is($parsed->{zone2}{value}, 78, 'zone 2 reading is 78');
    is($parsed->{zone3}{value}, 78, 'zone 3 reading is 78');
    is($parsed->{zone4}{value}, 78, 'zone 4 reading is 78');
    is($parsed->{zone2}{id}, 2, 'zone 2 id is 2');
    is($parsed->{sysval1}{index}, 0x14, 'sysval1 index is 20');
    is($parsed->{sysval2}{index}, 0x1C, 'sysval2 index is 28');

    # Build round-trip
    my $rebuilt = $parser->build($parsed);
    is($rebuilt, $raw, 'build(parse(raw)) round-trips');
};

subtest 'ZC parser: 0319 zone config round-trip' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    my $raw = $zc->get_register('0319');
    is(length($raw), 8, '0319 raw data is 8 bytes');

    my $parser = CarBus::Frame::subparser('0319', 'ZoneControl');
    ok($parser, 'device-scoped 0319 parser found');

    my $parsed = $parser->parse($raw);
    is($parsed->{config_byte1}, 0, 'config_byte1 is 0');
    is_deeply($parsed->{zone_slots}, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF], 'unused slots are 0xFF');

    my $rebuilt = $parser->build($parsed);
    is($rebuilt, $raw, 'build(parse(raw)) round-trips');
};

subtest 'ZC parser: 0302 parsed via frame auto-parse' => sub {
    my $td = tempdir(CLEANUP => 1);
    my $bus = MockBus->new;
    my $zc = CarBus::ZoneController->new(
        bus   => $bus,
        store => CHI->new(driver => 'File', root_dir => $td),
    );
    $zc->initialize_defaults();

    # Build a reply frame from ZC for register 0302
    my $reply = $zc->handle_frame(CarBus::Frame->new(
        src => 'Thermostat', src_bus => 1,
        dst => 'ZoneControl', dst_bus => 1,
        cmd => 'read',
        payload_raw => "\x00\x03\x02",
    ));
    ok($reply, 'got reply');
    $reply->frame;

    # The auto-parsed payload should use the ZoneControl-scoped parser
    my $payload = $reply->struct->{payload};
    ok($payload, 'payload auto-parsed');
    is(ref($payload), 'HASH', 'payload is a hash (not unknown)');
    is($payload->{zone_count}, 4, 'auto-parsed zone_count');
    is($payload->{zone2}{value}, 78, 'auto-parsed zone 2 reading');
};

done_testing;
