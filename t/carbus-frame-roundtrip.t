#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use CarBus::Frame;
use CarBus::SAM;  # Registers 030D, 3B02, 3B03 parsers via add_parser

# ============================================================================
# Helper: construct a valid frame hex string using Frame module itself
# ============================================================================
sub build_frame_hex {
    my (%args) = @_;
    my $f = CarBus::Frame->new(
        src_bus     => $args{src_bus} // 0,
        src         => $args{src}     // 'SAM',
        dst_bus     => $args{dst_bus} // 0,
        dst         => $args{dst}     // 'Thermostat',
        pid         => 0,
        ext         => 0,
        cmd         => $args{cmd}     // 'read',
        payload_raw => $args{payload} // '',
    );
    return $f->frame_hex;
}

# ============================================================================
# Test 1: Frame parse -> build round-trip preserves bytes
# ============================================================================
subtest 'parse/build round-trip preserves bytes' => sub {
    my @cases = (
        { label => 'read 0104',  cmd => 'read',  payload => "\x00\x01\x04" },
        { label => 'write 030D', cmd => 'write', payload => "\x00\x03\x0D\x3F" },
        { label => 'reply 0104', cmd => 'reply', payload => "\x00\x01\x04" . ("X" x 20) },
    );

    plan tests => scalar(@cases) * 2;

    for my $case (@cases) {
        my $hex = build_frame_hex(
            src => 'Thermostat', dst => 'SAM',
            cmd => $case->{cmd}, payload => $case->{payload},
        );

        my $f = CarBus::Frame->new($hex);
        ok($f->valid, "$case->{label}: parsed frame valid");
        is($f->frame_hex, $hex, "$case->{label}: round-trip preserves hex");
    }
};

# ============================================================================
# Test 2: Register 0104 (device_info) parse/build round-trip
# ============================================================================
subtest 'register 0104 device_info round-trip' => sub {
    my $parser = CarBus::Frame::subparser('0104');
    ok($parser, 'subparser for 0104 exists');

    my $identity = {
        device    => 'SYSTEM ACCESS MODULE',
        location  => '',
        software  => 'CESR131379-03',
        model     => 'SYSTXCCSAM01',
        serial    => '1009N182206-',
        reference => '1009N182206-------------',
    };

    # Build binary from hash
    my $built = $parser->build($identity);
    is(length($built), 120, 'build() produces 120 bytes (24+24+16+20+12+24)');

    # Parse it back
    my $parsed = $parser->parse($built);
    is($parsed->{device},    $identity->{device},    'device round-trips');
    is($parsed->{location},  $identity->{location},  'location round-trips');
    is($parsed->{software},  $identity->{software},  'software round-trips');
    is($parsed->{model},     $identity->{model},     'model round-trips');
    is($parsed->{serial},    $identity->{serial},    'serial round-trips');
    is($parsed->{reference}, $identity->{reference}, 'reference round-trips');

    # Build again from parsed data - must be byte-identical
    my $rebuilt = $parser->build($parsed);
    is($rebuilt, $built, 'build(parse(build(x))) is byte-identical');
};

# ============================================================================
# Test 3: Full reply frame for 0104 round-trips with parsed payload
# ============================================================================
subtest 'full 0104 reply frame round-trip' => sub {
    my $parser = CarBus::Frame::subparser('0104');
    my $identity = {
        device    => 'SYSTEM ACCESS MODULE',
        location  => '',
        software  => 'CESR131379-03',
        model     => 'SYSTXCCSAM01',
        serial    => '1009N182206-',
        reference => '1009N182206-------------',
    };

    # Build reply payload: 3-byte prefix + register data
    my $register_data = $parser->build($identity);
    my $reply_payload = pack("C*", 0, 1, 4) . $register_data;
    is(length($reply_payload), 123, 'reply payload is 123 bytes (3 + 120)');

    # Create reply frame
    my $hex = build_frame_hex(
        src => 'SAM', dst => 'Thermostat',
        cmd => 'reply', payload => $reply_payload,
    );

    my $f = CarBus::Frame->new($hex);
    ok($f->valid, 'reply frame is valid');
    is($f->struct->{reg_string}, '0104', 'reg_string extracted');
    is($f->struct->{cmd}, 'reply', 'cmd is reply');

    # Verify payload parsing
    my $payload = $f->struct->{payload};
    is(ref($payload), 'HASH', 'payload parses to hash');
    is($payload->{device},    'SYSTEM ACCESS MODULE', 'device correct');
    is($payload->{software},  'CESR131379-03',       'software correct');
    is($payload->{serial},    '1009N182206-',        'serial correct');
    is($payload->{reference}, '1009N182206-------------', 'reference correct (24 bytes)');

    # Verify round-trip
    is($f->frame_hex, $hex, 'reply frame round-trips');

    # Verify payload_raw matches what we built
    is($f->struct->{payload_raw}, $reply_payload, 'payload_raw matches original');
};

# ============================================================================
# Test 4: Emulated SAM response format matches real SAM format
# This tests the exact payload format that _handle_read produces
# ============================================================================
subtest 'emulated response format matches real SAM' => sub {
    my $parser = CarBus::Frame::subparser('0104');
    my $identity = {
        device    => 'SYSTEM ACCESS MODULE',
        location  => '',
        software  => 'CESR131379-03',
        model     => 'SYSTXCCSAM01',
        serial    => '1009N182206-',
        reference => '1009N182206-------------',
    };

    # This is what _handle_read builds:
    # payload_raw = pack("C*", 0, table, row) . register_data
    my $register_data = $parser->build($identity);  # 120 bytes, NO prefix
    my $emulated_payload = pack("C*", 0, 1, 4) . $register_data;  # 123 bytes, WITH prefix

    # A real SAM response has the same format
    is(length($emulated_payload), 123, 'emulated payload is 123 bytes');

    # Parse it as a frame payload
    my $hex = build_frame_hex(
        src => 'SAM', dst => 'Thermostat',
        cmd => 'reply', payload => $emulated_payload,
    );
    my $f = CarBus::Frame->new($hex);
    ok($f->valid, 'emulated response frame is valid');

    my $payload = $f->struct->{payload};
    is($payload->{device},    $identity->{device},    'emulated device matches');
    is($payload->{serial},    $identity->{serial},    'emulated serial matches');
    is($payload->{reference}, $identity->{reference}, 'emulated reference matches');

    # Build the same frame from struct (what spoof_device_info does)
    # and verify byte-identical output
    my $hex2 = build_frame_hex(
        src => 'SAM', dst => 'Thermostat',
        cmd => 'reply', payload => $emulated_payload,
    );
    is($hex2, $hex, 'same payload produces same frame');
};

# ============================================================================
# Test 5: Register 030D (sam_status) round-trip
# ============================================================================
subtest 'register 030D sam_status round-trip' => sub {
    my $parser = CarBus::Frame::subparser('030D');
    ok($parser, 'subparser for 030D exists');

    my $data = {
        val1 => 61, val2 => 62, val3 => 63,
        reserved1 => 0, reserved2 => 0, reserved3 => 0, reserved4 => 0,
    };
    my $built = $parser->build($data);
    my $parsed = $parser->parse($built);

    is($parsed->{val1}, 61, 'val1 round-trips');
    is($parsed->{val2}, 62, 'val2 round-trips');
    is($parsed->{val3}, 63, 'val3 round-trips');

    my $rebuilt = $parser->build($parsed);
    is($rebuilt, $built, 'build(parse(build(x))) is byte-identical');
};

# ============================================================================
# Test 6: Frame construction from hash (like _handle_read does)
# ============================================================================
subtest 'frame construction from hash' => sub {
    my $parser = CarBus::Frame::subparser('0104');
    my $identity = {
        device => 'TEST', location => '', software => 'SW',
        model => 'MODEL', serial => 'SERIAL', reference => 'REF',
    };
    my $data = $parser->build($identity);

    # Construct frame the way _handle_read does
    my $f = CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => 0,
        dst     => 'Thermostat',
        dst_bus => 0,
        cmd     => 'reply',
        payload_raw => pack("C*", 0, 1, 4) . $data,
    );

    # frame() rebuilds binary and reparses, making struct fields consistent
    my $binary = $f->frame;
    ok(defined $binary, 'frame() produces binary');
    ok($f->valid, 'constructed frame is valid');
    is($f->struct->{reg_string}, '0104', 'reg_string extracted');
    is($f->struct->{payload}{device}, 'TEST', 'payload parsed correctly');

    my $f2 = CarBus::Frame->new($binary);
    ok($f2->valid, 're-parsed frame is valid');
    is($f2->struct->{payload}{device}, 'TEST', 're-parsed payload matches');
    is($f2->struct->{payload_raw}, $f->struct->{payload_raw}, 'payload_raw round-trips');
};

done_testing();
