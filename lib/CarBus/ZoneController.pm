package CarBus::ZoneController;
use strict;
use warnings;
use feature ':5.10';
use Moo;
use Data::ParseBinary;
use CarBus::Frame;
use CarBus::Device;

# ⚠️  SAFETY WARNING
#
# Zone Controller emulation is inherently riskier than SAM emulation.
# If the SAM goes offline, the thermostat continues with a minor error.
# If the Zone Controller disappears or feeds bad data, conditioning can
# STOP ENTIRELY.
#
# Neither Infinitude nor InfinitESP is a replacement for legitimate OEM
# hardware in critical HVAC applications. These are experimental projects
# for protocol research and personal use, provided AS IS with no warranty.
#
# This module is a DEVELOPMENT AND REFERENCE IMPLEMENTATION for prototyping
# the CarBus ZC protocol. Production use belongs in InfinitESP on dedicated
# hardware.
#
# The wash-to-primary safety mechanism (Phase 0) MUST remain active at all
# times. Zone temperatures must never sit on stale sensor data indefinitely.

extends 'CarBus::Device';

# Zone Controller key mapping for cycle/runtime registers
# Format: 1-byte key + 3-byte big-endian unsigned value
my %zc_key_names = (
    0x38 => 'unknown_0x38',  0x39 => 'unknown_0x39',
    0x3A => 'unknown_0x3A',  0x3B => 'unknown_0x3B',
    0x2B => 'poweron_cycles', 0x2C => 'poweron_hours',
);

my $ZC_KVEntry = Struct('entry',
    Byte('key'),
    Byte('b1'), Byte('b2'), Byte('b3'),
    Value('value', sub {
        my $c = $_->ctx;
        ($c->{b1} << 16) | ($c->{b2} << 8) | $c->{b3}
    }),
    Value('name', sub {
        my $k = $_->ctx->{key};
        $zc_key_names{$k} // sprintf("unknown_0x%02X", $k)
    }),
);

my $GreedyZCKV = sub {
    my ($name) = @_;
    Struct($name,
        Array(sub {
            my $stream = $_->stream;
            return 0 unless $stream && defined ${$stream->{data}};
            my $len = length(${$stream->{data}});
            my $pos = $stream->{offset} // 0;
            my $remaining = $len - $pos;
            return 0 unless $remaining >= 4;
            return int($remaining / 4);
        }, $ZC_KVEntry),
    );
};

has '+src_name' => (default => 'ZoneControl');

# Custom device identity
has device_identity => (is => 'rw', default => sub {
    my $parser = CarBus::Frame::subparser('0104', 'ZoneControl');
    $parser->build({
        model     => 'SYSTXCC4ZC01',
        device    => 'INFINITUDE 4 ZONE',
        location  => '',
        software  => 'INFD-ZC-01',
        reference => '000000000001',
        serial    => '2624ZC0001',
    });
});

# Static system values from captures (0x14=20, 0x1c=28) — never change
has system_values => (is => 'ro', default => sub { [0x14, 0x1c] });

# Damper positions per zone (1-4). 0x0F = open, 0x00 = closed.
has damper_positions => (is => 'rw', default => sub { [0, 0, 0, 0] });

# Zone temperatures in °F (index 0 unused, zones 2-4).
# Converted to raw values for register 0302 via _f_to_raw().
has zone_temps_f => (is => 'rw', default => sub { [0, 73, 73, 73] });

# Baseline temperatures (what zone_temps_f reverts to when dampers close)
has zone_temps_baseline_f => (is => 'ro', default => sub { [0, 73, 73, 73] });

# --- 0319 damper state tracking ---
#
# The real ZC updates register 0319 to reflect which zone dampers are open/closed.
# This is the feedback mechanism the thermostat uses during duct evaluation.
# Without 0319 updates, the thermostat hangs at "opening all zones."
#
# Timeline from feisley install (real 4-zone system with physical dampers):
#
#   Initial discovery (ZC self-scan, no 0308 writes):
#     +0.3s:  0f 00 00 0f   zones 1&4 detected
#     +10.2s: 0f 00 0a 0f   zone 3 transitioning (0x0a = partial)
#     +135s:  0f 00 0a 00   zone 4 cleared
#     +155s:  0f 00 00 00   zone 3 closed
#     +177s:  0f 0f 00 00   zone 2 discovered
#     +201s:  0f 0f 0f 00   zone 3 discovered
#     +217s:  0f 0f 0f 0f   all 4 zones discovered
#
#   Duct eval (after 0308 damper writes, ~15-20s delay per transition):
#     0308=0f000000 → 0319: 0f0f0f0f → 0f000f0f → 0f00000f → 0f000000
#     0308=000f0000 → 0319: 0f0f0000 → 000f0000
#     0308=00000f00 → 0319: 000f0f00 → 00000f00
#     0308=0000000f → 0319: 00000f0f → 0000000f
#     0308=0000000f → 0319: 00000000 (done)
#
# The ZC independently scans its damper connections at power-up, then during
# duct eval mirrors the 0308 commands into 0319 bytes 0-3 with ~15-20s delay.
# Bytes 4-7 are always 0xFF (unused zone slots).

# Timestamp of last 0308 write (for transition delay)
has last_0308_time => (is => 'rw', default => 0);

# Target 0319 state (what we're transitioning toward based on 0308 writes)
has target_0319 => (is => 'rw', default => sub { [0x0F, 0x00, 0x00, 0x0F] });

# Current 0319 state (what we return on reads, transitions toward target)
has current_0319 => (is => 'rw', default => sub { [0x0F, 0x00, 0x00, 0x0F] });

# Startup time for initial zone discovery sequence
has startup_time => (is => 'rw', default => sub { time });

# --- Zone sensor value encoding (register 0302) ---
#
#   value = (°F - 64) × 16
#   °F = value / 16 + 64
#
# Range: 64.0°F (value=0) to 79.9°F (value=255)
# Resolution: 1/16 = 0.0625°F

sub _f_to_raw {
    my ($self, $temp_f) = @_;
    my $raw = int(($temp_f - 64) * 16 + 0.5);
    $raw = 0   if $raw < 0;
    $raw = 255 if $raw > 255;
    return $raw;
}

sub _raw_to_f {
    my ($self, $raw) = @_;
    return undef if !defined $raw;
    return $raw / 16 + 64;
}

sub BUILD {
    my $self = shift;
    $self->initialize_defaults();

    # Dynamic read handler for 0302: returns current zone temperatures.
    $self->on_read('0302', sub {
        my $t = $self->zone_temps_f;
        my $sv = $self->system_values;

        my $parser = CarBus::Frame::subparser('0302', 'ZoneControl');
        return $parser->build({
            zone_count    => 4,
            zone1_present => 1,
            zone2 => { tag => 0x01, id => 2, reading_tag => 0x04, value => $self->_f_to_raw($t->[1]) },
            zone3 => { tag => 0x01, id => 3, reading_tag => 0x04, value => $self->_f_to_raw($t->[2]) },
            zone4 => { tag => 0x01, id => 4, reading_tag => 0x04, value => $self->_f_to_raw($t->[3]) },
            sysval1 => { tag => 0x04, index => $sv->[0], val_hi => 0, val_lo => 0 },
            sysval2 => { tag => 0x04, index => $sv->[1], val_hi => 0, val_lo => 0 },
        });
    });

    # Dynamic read handler for 0319: returns current damper state.
    # Updates state toward target based on 0308 writes and startup discovery.
    $self->on_read('0319', sub {
        $self->_update_0319();
        my $cur = $self->current_0319;
        return pack("C*", $cur->[0], $cur->[1], $cur->[2], $cur->[3], 0xFF, 0xFF, 0xFF, 0xFF);
    });
}

# --- 0319 state machine ---
#
# Two modes:
# 1. Startup discovery: ZC self-scans for connected dampers over ~4 minutes.
#    Sequence: [0f,00,00,0f] → [0f,00,0a,0f] → [0f,00,0a,00] → [0f,00,00,00]
#              → [0f,0f,00,00] → [0f,0f,0f,00] → [0f,0f,0f,0f]
#
# 2. Duct eval: ZC mirrors 0308 damper commands into 0319 with ~15-20s delay.
#    After a 0308 write, target_0319 is set to match the damper payload.
#    current_0319 transitions toward target one zone at a time with delays.

# Discovery phases: [current_state, elapsed_seconds_to_reach]
my @discovery_sequence = (
    [[0x0F, 0x00, 0x00, 0x0F], 0],    # +0s: initial
    [[0x0F, 0x00, 0x0A, 0x0F], 10],    # +10s: zone 3 transitioning
    [[0x0F, 0x00, 0x0A, 0x00], 135],   # +135s: zone 4 cleared
    [[0x0F, 0x00, 0x00, 0x00], 155],   # +155s: zone 3 closed
    [[0x0F, 0x0F, 0x00, 0x00], 177],   # +177s: zone 2 discovered
    [[0x0F, 0x0F, 0x0F, 0x00], 201],   # +201s: zone 3 discovered
    [[0x0F, 0x0F, 0x0F, 0x0F], 217],   # +217s: all zones found
);

sub _update_0319 {
    my $self = shift;

    my $elapsed = time - $self->startup_time;
    my $last_0308 = $self->last_0308_time;

    # If we've received a 0308 write, use duct eval mode (mirror damper commands)
    if ($last_0308 > 0) {
        my $since_write = time - $last_0308;

        if ($since_write >= 15) {
            # Enough time has passed — transition current toward target
            my $cur = $self->current_0319;
            my $tgt = $self->target_0319;
            my $changed = 0;

            for my $i (0..3) {
                if ($cur->[$i] ne $tgt->[$i]) {
                    # First mismatched zone gets updated this cycle
                    $cur->[$i] = $tgt->[$i];
                    $changed = 1;
                    last;
                }
            }

            if ($changed) {
                $self->current_0319($cur);
                # Reset timer so next zone transitions after another 15s
                $self->last_0308_time(time);
            }
        }
        return;
    }

    # No 0308 writes yet — use startup discovery sequence
    my $state = $discovery_sequence[0][0];
    for my $entry (@discovery_sequence) {
        my ($phase_state, $phase_time) = @$entry;
        if ($elapsed >= $phase_time) {
            $state = $phase_state;
        } else {
            last;
        }
    }
    $self->current_0319([@$state]);
}

# --- Device-scoped parsers ---

# Register 0302 — Zone sensor readings (24 bytes, fixed layout)
CarBus::Frame->add_device_parser('ZoneControl', '0302',
    Struct('zc_zone_readings',
        Byte('zone_count'),
        Byte('zone1_present'),
        Padding(2),
        Struct('zone2', Byte('tag'), Byte('id'), Byte('reading_tag'), Byte('value')),
        Struct('zone3', Byte('tag'), Byte('id'), Byte('reading_tag'), Byte('value')),
        Struct('zone4', Byte('tag'), Byte('id'), Byte('reading_tag'), Byte('value')),
        Struct('sysval1', Byte('tag'), Byte('index'), Byte('val_hi'), Byte('val_lo')),
        Struct('sysval2', Byte('tag'), Byte('index'), Byte('val_hi'), Byte('val_lo')),
    )
);

# Register 0319 — Zone damper state (8 bytes)
#
# Bytes 0-3: zone damper status (0x0F=open/active, 0x0A=transitioning, 0x00=closed/inactive)
# Bytes 4-7: always 0xFF (unused zone slots)
#
# Updated by the ZC to reflect damper state. The thermostat reads this during
# duct evaluation to confirm dampers actually moved.
CarBus::Frame->add_device_parser('ZoneControl', '0319',
    Struct('zc_zone_config',
        Byte('zone1'), Byte('zone2'), Byte('zone3'), Byte('zone4'),
        Array(4, Byte('unused')),
    )
);

# Register 030d — Unknown (7 bytes, always zeros)
CarBus::Frame->add_device_parser('ZoneControl', '030d',
    Struct('zc_zeros',
        Array(7, Byte('data')),
    )
);

# Register 3404 — Write/heartbeat flag (1 byte)
CarBus::Frame->add_device_parser('ZoneControl', '3404',
    Struct('zc_heartbeat',
        Byte('flag'),
    )
);

# Register 0310 — Cycle counters
CarBus::Frame->add_device_parser('ZoneControl', '0310', $GreedyZCKV->('zc_cycle_counters'));

# Register 0311 — Runtime hours
CarBus::Frame->add_device_parser('ZoneControl', '0311', $GreedyZCKV->('zc_runtime_hours'));

# Register 3405 — Presence probe (discovery register)
CarBus::Frame->add_device_parser('ZoneControl', '3405',
    Struct('zc_presence',
        Byte('data'),
    )
);

# --- Register initialization ---

sub initialize_defaults {
    my $self = shift;

    return if $self->store->get('registers');

    # Register 0104 - Device info (raw bytes from real ZC capture)
    $self->set_register('0104', $self->device_identity);

    # Register 0302 - Zone sensor readings (built dynamically by on_read handler)
    $self->set_register('0302', $self->_build_0302());

    # Register 0319 - Zone damper state (built dynamically by on_read handler)
    # Initial value matches first discovery phase: zones 1&4 detected
    $self->set_register('0319', pack("C*", 0x0F, 0x00, 0x00, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF));

    # Register 030d - Always zeros
    $self->set_register('030d', pack("C*", 0, 0, 0, 0, 0, 0, 0));

    # Register 3404 - Heartbeat flag
    $self->set_register('3404', pack("C", 0x00));

    # Register 3405 - Presence probe (discovery register, 3 bytes)
    $self->set_register('3405', pack("C*", 0x00, 0x00, 0x00));

    # Register 0310 - Cycle counters (3 entries × 4 bytes = 12 bytes)
    # Values from real SYSTXCC4ZC01 capture (feisley-install.jsonl)
    $self->set_register('0310', pack("C*",
        0x38, 0x00, 0x00, 0x01,
        0x39, 0x00, 0x00, 0x01,
        0x2B, 0x00, 0x00, 0x7E,
    ));

    # Register 0311 - Runtime counters (3 entries × 4 bytes = 12 bytes)
    # Values from real SYSTXCC4ZC01 capture (feisley-install.jsonl)
    $self->set_register('0311', pack("C*",
        0x3A, 0x00, 0x00, 0x00,
        0x3B, 0x00, 0x00, 0x00,
        0x2C, 0x00, 0x7E, 0xED,
    ));
}

# Build register 0302 payload from zone_temps_f (°F → raw value)
sub _build_0302 {
    my $self = shift;
    my $t = $self->zone_temps_f;
    my $sv = $self->system_values;

    my $parser = CarBus::Frame::subparser('0302', 'ZoneControl');
    return $parser->build({
        zone_count    => 4,
        zone1_present => 1,
        zone2 => { tag => 0x01, id => 2, reading_tag => 0x04, value => $self->_f_to_raw($t->[1]) },
        zone3 => { tag => 0x01, id => 3, reading_tag => 0x04, value => $self->_f_to_raw($t->[2]) },
        zone4 => { tag => 0x01, id => 4, reading_tag => 0x04, value => $self->_f_to_raw($t->[3]) },
        sysval1 => { tag => 0x04, index => $sv->[0], val_hi => 0, val_lo => 0 },
        sysval2 => { tag => 0x04, index => $sv->[1], val_hi => 0, val_lo => 0 },
    });
}

# Update the temperature reading reported for a zone.
#
# This is a sensor state update, not a control command. It sets the value
# that register 0302 will report to the thermostat for the given zone.
# The thermostat reads this and decides what to do with it.
#
# Zone 1 is the thermostat's own sensor — only zones 2-4 are valid here.
sub update_zone_reading {
    my ($self, $zone, $temp_f) = @_;
    return unless $zone >= 2 && $zone <= 4;

    my $t = $self->zone_temps_f;
    $t->[$zone - 1] = $temp_f;
    $self->zone_temps_f($t);
    $self->set_register('0302', $self->_build_0302());
}

# Legacy alias
sub set_zone_temp { shift->update_zone_reading(@_) }

# Handle writes to register 0308 (damper positions) and 3404 (heartbeat).
#
# Real ZC behavior (from feisley-install.jsonl):
#   - BOTH 0308 and 3404 writes get a 1-byte 0x00 ACK (no register prefix)
#   - Frame: dst=0x20 src=0x60 len=1 cmd=reply payload=0x00
#
# After a 0308 write, the ZC updates register 0319 to mirror the damper
# positions with ~15-20s delay per zone. The thermostat reads 0319 to
# confirm dampers moved during duct evaluation.
around _handle_write => sub {
    my ($orig, $self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));
    my $value = substr($fs->{payload_raw}, 3);

    if ($reg_key eq '0308') {
        # Record damper positions
        my $dampers = $self->damper_positions;
        my @new_target;
        for my $i (0..3) {
            my $pos = unpack('C', substr($value, $i, 1));
            $dampers->[$i] = $pos;
            push @new_target, $pos;
        }
        $self->damper_positions($dampers);

        # Only reset transition timer when damper command CHANGES.
        # The thermostat sends the same 0308 repeatedly (~every 10-15s).
        # Resetting on every write would prevent the 15s transition delay from elapsing.
        my $old_target = $self->target_0319;
        my $changed = 0;
        for my $i (0..3) {
            if ($new_target[$i] != $old_target->[$i]) {
                $changed = 1;
                last;
            }
        }

        $self->target_0319(\@new_target);
        if ($changed) {
            $self->last_0308_time(time);
        }

        # ACK: 1 byte 0x00, no register prefix (matches real ZC)
        return $self->_reply($frame, pack("C", 0x00));
    }
    elsif ($reg_key eq '3404') {
        # ACK: 1 byte 0x00, no register prefix (matches real ZC)
        return $self->_reply($frame, pack("C", 0x00));
    }

    # Default: let base class handle it
    return $self->$orig($frame);
};

1;
