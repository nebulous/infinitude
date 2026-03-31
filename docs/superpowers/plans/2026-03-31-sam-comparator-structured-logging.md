# SAM Comparator Structured Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all sam-comparator STDOUT output with structured JSONL for machine-parseable all-day logging.

**Architecture:** Add a `log_event()` helper that stamps each event with ISO timestamp and elapsed time, then emits `encode_json`. Replace every `say` call with `log_event()` invocations. Remove `--verbose`/`--compare_only` flags. Single file change to `sam-comparator`.

**Tech Stack:** Perl, JSON module (core), Time::HiRes (already imported), POSIX::strftime (core)

---

### Task 1: Add imports, log helper, and startup event

**Files:**
- Modify: `sam-comparator` (top of file + startup section)

This task adds the `JSON` and `POSIX` imports, the `log_event()` helper, the `$start_time` variable, and replaces the startup/connection messages with a single `startup` event.

- [ ] **Step 1: Add imports and log_event helper**

Replace lines 1-15 header block with:

```perl
#!/usr/bin/env perl
use lib 'lib';
use strict;
use warnings;
use feature ':5.10';
$| = 1;  # Autoflush STDOUT
use CarBus;
use CarBus::SAM;
use CarBus::SAM::ASCII;
use CarBus::Frame;
use IO::Termios;
use IO::Socket::IP;
use Getopt::Long;
use JSON;
use POSIX qw(strftime);
use Time::HiRes qw(time sleep);

my $start_time = time();

sub log_event {
    my ($data) = @_;
    $data->{ts} = strftime("%Y-%m-%dT%H:%M:%S", gmtime) . sprintf(".%03dZ", int(($data->{_ms} // (int(time() * 1000) % 1000))));
    $data->{elapsed} = sprintf("%.3f", time() - $start_time);
    delete $data->{_ms};
    say encode_json($data);
}
```

- [ ] **Step 2: Remove verbose/compare_only from config defaults**

In the `$config` hash (around line 17), remove `verbose` and `compare_only` keys:

```perl
my $config = {
    network_bridge => '192.168.1.23:23',
    serial_sam => '/dev/cu.usbserial-A7039O5G',
    baud => '38400,8,n,1',
    clone => 0,
    serial_ascii => '/dev/cu.usbserial-211130',
    ascii_baud => '9600,8,n,1',
    ascii_idle_ms => 64,
    ascii_zone => 1,
    ascii_enabled => 1,
    report_interval => 120,
};
```

- [ ] **Step 3: Remove verbose/compare_only from GetOptions**

In the `GetOptions` call, remove `'verbose'` and `'compare_only'`:

```perl
GetOptions($config,
    'network_bridge=s',
    'serial_sam=s',
    'baud=s',
    'clone',
    'serial_ascii=s',
    'ascii_baud=s',
    'ascii_idle_ms=i',
    'ascii_zone=i',
    'ascii_enabled!',
    'report_interval=i',
    'help',
) or usage();
```

- [ ] **Step 4: Update usage() text**

Remove the "Display Options" section lines (`--verbose`, `--compare_only`) from the `usage()` subroutine. The "Display Options" section becomes just `--report_interval`, `--clone`, and `--help`:

```perl
sub usage {
    say "Usage: sam-comparator [options]";
    say "";
    say "Compares real SAM responses with emulated SAM responses.";
    say "Outputs structured JSONL (JSON Lines) to STDOUT.";
    say "Pipe to file: sam-comparator | tee log.jsonl";
    say "";
    say "ABCD Bus Options:";
    say "  --network_bridge <host:port>  TCP bridge to real bus (default: 192.168.1.23:23)";
    say "  --serial_sam <device>         Serial port with real SAM (default: /dev/cu.usbserial-A7039O5G)";
    say "  --baud <rate>                 Baud rate (default: 38400,8,n,1)";
    say "";
    say "ASCII Stimulation Options:";
    say "  --serial_ascii <device>       SAM RS-232 ASCII port (default: /dev/cu.usbserial-211130)";
    say "  --ascii_baud <rate>           ASCII baud rate (default: 9600,8,n,1)";
    say "  --ascii_idle_ms <ms>          Min bus idle ms before ASCII attempt (default: 64)";
    say "  --ascii_zone <1-8>            Zone for ASCII commands (default: 1)";
    say "  --noascii                     Disable ASCII stimulation";
    say "";
    say "Other Options:";
    say "  --report_interval <sec>       Stats report interval in seconds (default: 120)";
    say "  --clone                       Emulator mimics real SAM identity for byte-for-byte comparison";
    say "  --help                        Show this help";
    say "";
    say "Architecture:";
    say "  Thermostat <--bus--> Network Bridge (192.168.1.23:23)";
    say "                           |";
    say "                           +--> This script bridges frames to/from Real SAM";
    say "                           |      via /dev/cu.usbserial-A7039O5G (RS485, 38400 baud)";
    say "                           |      SAM is NOT on the physical bus - we forward frames";
    say "                           +--> Real SAM RS-232 ASCII (stimulation)";
    say "                                  via /dev/cu.usbserial-211130 (9600 baud)";
    say "                           +--> Emulated SAM (isolated, learning)";
    exit;
}
```

- [ ] **Step 5: Replace connection messages with startup event**

Replace lines 91-180 (connection setup through "Comparator running") with startup-event-emitting code. The key change: remove all the `say` calls for connection messages, and instead emit a single `startup` event after everything is initialized:

```perl
# --- Connect to ABCD bus ---

my ($host, $port) = split ':', $config->{network_bridge};
my $net_bus = CarBus->new(
    IO::Socket::IP->new(PeerHost => $host // 'localhost', PeerPort => $port // 23)
);

my $sam_bus;
if (-e $config->{serial_sam}) {
    $sam_bus = CarBus->new(
        IO::Termios->open($config->{serial_sam}, $config->{baud})
    );
} else {
    die "Serial SAM device not found: $config->{serial_sam}";
}

# Bridge between network and real SAM (emulator is NOT on bridge)
my $bridge = CarBus::Bridge->new(buslist => [$net_bus, $sam_bus]);

# --- Create emulated SAM with learning ---

my $emulated_sam = CarBus::SAM->new(
    bus => $net_bus,
    store => CHI->new(driver => 'Memory', global => 0),
    learn_mode => 1,
);
$emulated_sam->initialize_defaults();

# --- ASCII stimulation ---

my $ascii_sam;
if ($config->{ascii_enabled} && $config->{serial_ascii} && -e $config->{serial_ascii}) {
    $ascii_sam = eval {
        CarBus::SAM::ASCII->new(
            device => $config->{serial_ascii},
            baud   => $config->{ascii_baud},
            system => 1,
            zone   => $config->{ascii_zone},
        );
    };
}

# --- Emit startup event ---

log_event({
    event => 'startup',
    config => {
        network_bridge => $config->{network_bridge},
        serial_sam     => $config->{serial_sam},
        baud           => $config->{baud},
        clone          => $config->{clone},
        ascii_enabled  => $config->{ascii_enabled},
        ascii_baud     => $config->{ascii_baud},
        ascii_zone     => $config->{ascii_zone},
        ascii_idle_ms  => $config->{ascii_idle_ms},
        report_interval => $config->{report_interval},
    },
    ascii_connected     => ($ascii_sam ? 1 : 0),
    known_registers     => [sort @{$emulated_sam->known_registers()}],
    emulator_defaults_loaded => 1,
});
```

Remove the `Data::Dumper` import (line 14) since it is no longer needed.

- [ ] **Step 6: Verify the script parses**

Run: `perl -I lib -I ~/perl5/lib/perl5 -c sam-comparator`
Expected: `sam-comparator syntax OK` (it will fail on missing modules if run without hardware, but syntax check should pass)

- [ ] **Step 7: Commit**

```bash
git add sam-comparator
git commit -m "Add JSONL log_event helper, startup event, remove verbose/compare_only flags"
```

---

### Task 2: Replace main loop frame logging with JSONL events

**Files:**
- Modify: `sam-comparator` (main loop, lines ~188-308)

This task replaces all the `say` calls inside the main loop's frame processing with `log_event` calls for `frame`, `comparison`, and `learn` events.

- [ ] **Step 1: Replace frame processing section**

Replace the entire `for my $frame (@frames)` loop body (currently lines 188-308) with:

```perl
    for my $frame (@frames) {
        $stats{total_frames}++;
        $last_frame_time = time();
        my $fs = $frame->struct;
        my $src = $fs->{src} // 'unknown';
        my $dst = $fs->{dst} // 'unknown';
        my $cmd = $fs->{cmd} // 'unknown';
        my $reg = $fs->{reg_string} // '????';

        # Derive short bus name from frame's busname
        my $bus = ($frame->{busname} // '') =~ /Socket/ ? 'NET'
                : ($frame->{busname} // '') =~ /Termios|usbserial/ ? 'SAM'
                : ($frame->{busname} // 'unknown');

        # Emit frame event for every bus frame
        my $frame_event = {
            event       => 'frame',
            bus         => $bus,
            src         => $src,
            dst         => $dst,
            cmd         => $cmd,
            reg         => $reg,
            reg_name    => $fs->{reg_name} // undef,
            valid       => $fs->{valid} ? 1 : 0,
            hex         => $fs->{as_hex},
            payload_hex => $fs->{payload_hex},
        };
        $frame_event->{payload} = $fs->{payload} if $fs->{payload};
        log_event($frame_event);

        # Check for SAM queries (read or write to SAM)
        if (($dst eq 'SAM' || $dst eq 'FakeSAM') && ($cmd eq 'read' || $cmd eq 'write')) {
            $stats{sam_queries}++;
            $register_coverage{$reg}{real_hits}++;

            my $query_key = "$src:$reg:$cmd";

            # Pass query to emulated SAM
            my $emulated_response = $emulated_sam->handle_frame($frame);

            if ($emulated_response) {
                $pending_queries{$query_key} = {
                    query_frame => $frame,
                    emulated_response => $emulated_response,
                    timestamp => time,
                    compared => 0,
                };
            } else {
                # Gap: emulator has no response
                log_event({
                    event    => 'comparison',
                    reg      => $reg,
                    reg_name => $fs->{reg_name} // undef,
                    verdict  => 'gap',
                    real_hex => unpack("H*", $fs->{payload_raw} // ''),
                });
                $stats{emulator_only}++;
            }
        }

        # Check for SAM responses
        if ($src eq 'SAM' && $cmd eq 'reply') {
            my $reg = $fs->{reg_string};

            # Clone mode: capture real SAM's device identity for 0104
            if ($clone_mode && $reg && $reg eq '0104' && !$real_device_identity) {
                my $parsed = $fs->{payload};
                if ($parsed) {
                    $real_device_identity = $parsed;
                    $emulated_sam->set_device_identity($parsed);
                    log_event({
                        event  => 'clone',
                        reg    => '0104',
                        device => $parsed->{device} // 'unknown',
                        model  => $parsed->{model} // 'unknown',
                        serial => $parsed->{serial} // 'unknown',
                    });
                }
            }

            # Learn from real SAM responses for unknown registers
            if (defined $reg && length($fs->{payload_raw}) > 3) {
                my $raw_data = substr($fs->{payload_raw}, 3);
                if ($emulated_sam->learn_register($reg, $raw_data)) {
                    log_event({
                        event    => 'learn',
                        reg      => $reg,
                        reg_name => $fs->{reg_name} // undef,
                        bytes    => length($raw_data),
                    });
                    $stats{learned_registers}++;
                }
            }

            # Find matching pending query for comparison
            for my $key (keys %pending_queries) {
                next if $pending_queries{$key}{compared};
                next unless $key =~ /^([^:]+):$reg:/;

                my $pending = $pending_queries{$key};
                $stats{comparisons}++;
                $register_coverage{$reg}{emu_hits}++;

                # Compare raw payload bytes
                my $real_data = $fs->{payload_raw} // '';
                my $emu_data = $pending->{emulated_response}->struct->{payload_raw} // '';
                my $match = $real_data eq $emu_data;

                my $cmp_event = {
                    event     => 'comparison',
                    reg       => $reg,
                    reg_name  => $fs->{reg_name} // undef,
                    verdict   => $match ? 'match' : 'mismatch',
                    real_hex  => unpack("H*", $real_data),
                    emu_hex   => unpack("H*", $emu_data),
                };
                $cmp_event->{real_payload} = $fs->{payload} if $fs->{payload};
                my $emu_parsed = $pending->{emulated_response}->struct->{payload};
                $cmp_event->{emu_payload} = $emu_parsed if $emu_parsed;

                log_event($cmp_event);

                if ($match) {
                    $stats{matches}++;
                    $sam_sync_count++ unless $ascii_done;
                } else {
                    $stats{mismatches}++;
                    $register_coverage{$reg}{mismatches}++;
                }

                $pending->{compared} = 1;
                delete $pending_queries{$key};
                last;
            }
        }
    }
```

- [ ] **Step 2: Verify syntax**

Run: `perl -I lib -I ~/perl5/lib/perl5 -c sam-comparator`
Expected: `sam-comparator syntax OK`

- [ ] **Step 3: Commit**

```bash
git add sam-comparator
git commit -m "Replace main loop frame/comparison logging with JSONL events"
```

---

### Task 3: Replace ASCII, stats, timeout, and shutdown sections with JSONL

**Files:**
- Modify: `sam-comparator` (ASCII section, timeout cleanup, periodic report, END block)

This task replaces all remaining `say` calls with JSONL events.

- [ ] **Step 1: Replace ASCII stimulus section**

Replace the ASCII BLIGHT stimulus section (the `if ($ascii_sam && !$ascii_done...` block through the ASCII response check) with:

```perl
    # --- ASCII BLIGHT stimulus (fire-and-forget) ---
    if ($ascii_sam && !$ascii_done && !$ascii_pending
        && $sam_sync_count >= $ASCII_SYNC_THRESHOLD
        && (time() - $last_idle_time) >= ($config->{ascii_idle_ms} / 1000)) {

        $stats{ascii_commands}++;
        my $attempt = $stats{ascii_commands};

        my $fh = $ascii_sam->fh;
        $fh->blocking(0);
        while (1) {
            my $junk;
            my $n = sysread($fh, $junk, 4096);
            last unless $n && $n > 0;
        }
        syswrite($fh, "S1Z1FAN!AUTO\r\n");
        $ascii_pending = 1;
        $ascii_send_time = time();
        $ascii_buf = '';

        log_event({
            event   => 'ascii',
            phase   => 'send',
            command => 'S1Z1FAN!AUTO',
            attempt => $attempt,
            idle_ms => int((time() - $last_idle_time) * 1000),
        });
    }

    # --- ASCII response check (non-blocking) ---
    if ($ascii_sam && $ascii_pending) {
        my $fh = $ascii_sam->fh;
        my $chunk;
        my $n = sysread($fh, $chunk, 256);
        $ascii_buf .= $chunk if $n && $n > 0;

        if ($ascii_buf =~ /[\r\n]/) {
            $ascii_buf =~ s/[\r\n]+$//;
            $ascii_pending = 0;
            my $attempt = $stats{ascii_commands};

            if ($ascii_buf =~ /ACK/) {
                $ascii_done = 1;
                $ascii_post_start = time();
                $stats{ascii_responses}++;
                log_event({
                    event       => 'ascii',
                    phase       => 'response',
                    attempt     => $attempt,
                    response    => 'ACK',
                    latency_ms  => int((time() - $ascii_send_time) * 1000),
                });
            } elsif ($ascii_buf ne '') {
                log_event({
                    event    => 'ascii',
                    phase    => 'response',
                    attempt  => $attempt,
                    response => $ascii_buf,
                    latency_ms => int((time() - $ascii_send_time) * 1000),
                });
            }
        } elsif (time() - $ascii_send_time > $ASCII_RESP_TIMEOUT) {
            $ascii_pending = 0;
            $stats{ascii_timeouts}++;
            log_event({
                event   => 'ascii',
                phase   => 'timeout',
                attempt => $stats{ascii_commands},
            });
        }
    }
```

- [ ] **Step 2: Remove post-ASCII logging section**

Delete the entire post-ASCII traffic logging block (the `if ($ascii_done && $ascii_post_start...` section). The frame event already captures every frame with timestamps, so post-ASCII frames can be filtered by elapsed time in post-processing.

- [ ] **Step 3: Replace timeout cleanup**

Replace the timeout cleanup section with a silent version (no log output for timeouts — they're implicit in comparisons that never appear):

```perl
    # --- Timeout cleanup ---
    my $now = time;
    for my $key (keys %pending_queries) {
        if ($now - $pending_queries{$key}{timestamp} > 5) {
            delete $pending_queries{$key};
        }
    }
```

- [ ] **Step 4: Replace periodic coverage report with stats event**

Replace the periodic report section with:

```perl
    # --- Periodic stats event ---
    state $last_report_time = 0;
    if (time - $last_report_time >= $config->{report_interval}) {
        my %coverage_out;
        for my $r (sort keys %register_coverage) {
            my $cov = $register_coverage{$r};
            $coverage_out{$r} = {
                real       => $cov->{real_hits} // 0,
                emu        => $cov->{emu_hits} // 0,
                mismatches => $cov->{mismatches} // 0,
            };
        }
        log_event({
            event              => 'stats',
            total_frames       => $stats{total_frames},
            sam_queries        => $stats{sam_queries},
            comparisons        => $stats{comparisons},
            matches            => $stats{matches},
            mismatches         => $stats{mismatches},
            emulator_gaps      => $stats{emulator_only},
            learned_registers  => $stats{learned_registers},
            register_coverage  => \%coverage_out,
            known_registers    => [sort @{$emulated_sam->known_registers()}],
            ascii              => {
                sent     => $stats{ascii_commands},
                ok       => $stats{ascii_responses},
                timeouts => $stats{ascii_timeouts},
            },
        });
        $last_report_time = time;
    }
```

- [ ] **Step 5: Replace END block with shutdown event**

Replace the entire END block with:

```perl
END {
    return unless $emulated_sam && %stats;
    my %coverage_out;
    for my $r (sort keys %register_coverage) {
        my $cov = $register_coverage{$r};
        $coverage_out{$r} = {
            real       => $cov->{real_hits} // 0,
            emu        => $cov->{emu_hits} // 0,
            mismatches => $cov->{mismatches} // 0,
        };
    }
    log_event({
        event              => 'shutdown',
        total_frames       => $stats{total_frames},
        sam_queries        => $stats{sam_queries},
        comparisons        => $stats{comparisons},
        matches            => $stats{matches},
        mismatches         => $stats{mismatches},
        emulator_gaps      => $stats{emulator_only},
        learned_registers  => $stats{learned_registers},
        register_coverage  => \%coverage_out,
        known_registers    => [sort @{$emulated_sam->known_registers()}],
    });
}
```

- [ ] **Step 6: Verify syntax**

Run: `perl -I lib -I ~/perl5/lib/perl5 -c sam-comparator`
Expected: `sam-comparator syntax OK`

- [ ] **Step 7: Commit**

```bash
git add sam-comparator
git commit -m "Replace ASCII, stats, and shutdown output with JSONL events"
```

---

### Task 4: Add JSONL smoke test

**Files:**
- Create: `t/sam-comparator-jsonl.t`

This test validates that the JSONL output is valid JSON and contains expected event types, without needing real hardware.

- [ ] **Step 1: Write the test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use feature ':5.10';
use Test::More;
use JSON;

# Test that log_event produces valid JSONL
# We parse the output of a minimal script that uses the log_event pattern

my $perl = $^X;
my $inc = join(' ', map { "-I $_" } @INC);

# Test 1: Basic JSON validity - run the script's syntax check
my $syntax_ok = system("$perl -I lib -c sam-comparator 2>/dev/null") == 0;
ok($syntax_ok, 'sam-comparator syntax check passes');

# Test 2: Verify JSON module is importable
require_ok('JSON');
can_ok('JSON', 'encode_json');

# Test 3: Verify log_event output format matches spec
my $test_script = <<'ENDSCRIPT';
use strict;
use warnings;
use feature ':5.10';
use JSON;
use POSIX qw(strftime);
use Time::HiRes qw(time);

my $start_time = time();

sub log_event {
    my ($data) = @_;
    $data->{ts} = strftime("%Y-%m-%dT%H:%M:%S", gmtime) . sprintf(".%03dZ", int(($data->{_ms} // (int(time() * 1000) % 1000))));
    $data->{elapsed} = sprintf("%.3f", time() - $start_time);
    delete $data->{_ms};
    say encode_json($data);
}

log_event({ event => 'startup', known_registers => ['0104', '3B02'] });
log_event({ event => 'frame', src => 'Thermostat', dst => 'SAM', cmd => 'read', reg => '3B02' });
log_event({ event => 'comparison', reg => '3B02', verdict => 'match', real_hex => 'aabb', emu_hex => 'aabb' });
log_event({ event => 'learn', reg => '3B05', bytes => 42 });
log_event({ event => 'ascii', phase => 'send', attempt => 1 });
log_event({ event => 'stats', total_frames => 100 });
log_event({ event => 'shutdown', total_frames => 1000 });
ENDSCRIPT

my $output = `$perl -e '$test_script' 2>/dev/null`;
my @lines = grep { $_ ne '' } split /\n/, $output;
is(scalar @lines, 7, 'log_event produces 7 JSONL lines');

my @expected_events = qw(startup frame comparison learn ascii stats shutdown);
for my $i (0..$#expected_events) {
    my $obj = decode_json($lines[$i]);
    is($obj->{event}, $expected_events[$i], "line $i is $expected_events[$i] event");
    like($obj->{ts}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/, "line $i has ISO timestamp");
    like($obj->{elapsed}, qr/^\d+\.\d{3}$/, "line $i has elapsed seconds");
}

# Test 4: Verify frame event has all required fields
my $frame_obj = decode_json($lines[1]);
is($frame_obj->{src}, 'Thermostat', 'frame event has src');
is($frame_obj->{dst}, 'SAM', 'frame event has dst');
is($frame_obj->{cmd}, 'read', 'frame event has cmd');
is($frame_obj->{reg}, '3B02', 'frame event has reg');

# Test 5: Verify comparison event has verdict and hex data
my $cmp_obj = decode_json($lines[2]);
is($cmp_obj->{verdict}, 'match', 'comparison has verdict');
is($cmp_obj->{real_hex}, 'aabb', 'comparison has real_hex');
is($cmp_obj->{emu_hex}, 'aabb', 'comparison has emu_hex');

done_testing;
```

- [ ] **Step 2: Run the test**

Run: `perl -I lib -I ~/perl5/lib/perl5 t/sam-comparator-jsonl.t`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add t/sam-comparator-jsonl.t
git commit -m "Add JSONL smoke test for sam-comparator log output"
```

---

## Self-Review Checklist

**Spec coverage:**
- startup event: Task 1 Step 5
- frame event (every bus frame): Task 2 Step 1
- comparison event (match/mismatch/gap): Task 2 Step 1
- learn event: Task 2 Step 1
- ascii event (send/response/timeout): Task 3 Step 1
- stats event (periodic): Task 3 Step 4
- shutdown event (END block): Task 3 Step 5
- ISO timestamps: Task 1 Step 1 (log_event helper)
- elapsed time: Task 1 Step 1 (log_event helper)
- Remove --verbose/--compare_only: Task 1 Steps 2-4
- Remove Data::Dumper import: Task 1 Step 5

**Placeholder scan:** No TBDs, no TODOs, no "implement later", all code shown inline.

**Type consistency:** All event types use `reg` (not `register`), `reg_name`, `verdict` consistently across tasks. `log_event` signature is `($hashref)` throughout.
