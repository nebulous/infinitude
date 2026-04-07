# EMULATE_SAM RS485 Thermostat Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable infinitude to control the thermostat via RS485 when `EMULATE_SAM=1` is set, starting with temperature setpoint control as POC.

**Architecture:** `EMULATE_SAM` env var activates in-process SAM emulation. `CarBus::SAM` gets a configurable `emulated_src` attribute (default `FakeSAM`, set to `SAM` for real emulation), a new domain method (`set_zone_setpoint`), and exception replies for unknown registers. The infinitude app hooks into the existing setpoint API handler to route writes through RS485 with XML fallback.

**Tech Stack:** Perl, Mojolicious, CarBus::SAM, CarBus::Frame, CHI

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/CarBus/SAM.pm` | Modify | Add `emulated_src` attr, `_exception_reply`, `set_zone_setpoint`, use `$self->emulated_src` in all reply frames |
| `infinitude` | Modify | Read env var, init SAM with `emulated_src => 'SAM'`, intercept frames, hook setpoint API |
| `t/sam-emulator.t` | Modify | Add tests for exception replies, `emulated_src`, and `set_zone_setpoint` |
| `t/carbus-develop.t` | Modify | Update test that expects `undef` for unknown register reads |

---

### Task 1: Add `emulated_src` attribute to CarBus::SAM

The source address used in all reply frames. Defaults to `FakeSAM` (0x93) for tools like sam-comparator. Set to `SAM` (0x92) when infinitude runs as the real emulator.

**Files:**
- Modify: `lib/CarBus/SAM.pm:14` (after `handlers` attribute)
- Modify: `lib/CarBus/SAM.pm:394,419` (replace hardcoded `'FakeSAM'` in `_handle_read` and `_handle_write`)
- Modify: `lib/CarBus/SAM.pm:429-437` (update `read_thermostat`/`write_thermostat` to pass source)
- Modify: `t/sam-emulator.t`

- [ ] **Step 1: Write the failing tests**

Append to `t/sam-emulator.t` before `done_testing()`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/sam-emulator.t`
Expected: FAIL — `Can't locate object method "emulated_src"`.

- [ ] **Step 3: Implement `emulated_src` attribute**

Add after the `handlers` attribute in `lib/CarBus/SAM.pm` (after line 14):

```perl
has emulated_src => (is => 'ro', default => 'FakeSAM');
```

Then replace all hardcoded `'FakeSAM'` in reply frames with `$self->emulated_src`. There are two in `_handle_read` (line 394) and `_handle_write` (line 419):

In `_handle_read`, change:
```perl
        src     => 'FakeSAM',
```
to:
```perl
        src     => $self->emulated_src,
```

In `_handle_write`, change:
```perl
        src     => 'FakeSAM',
```
to:
```perl
        src     => $self->emulated_src,
```

Update `write_thermostat` and `read_thermostat` to pass the source address through. Replace the existing methods:

```perl
# Convenience: read from thermostat
sub read_thermostat {
    my ($self, $table, $row) = @_;
    return $self->bus->read_register('Thermostat', $table, $row, {src => $self->emulated_src});
}

# Convenience: write to thermostat
sub write_thermostat {
    my ($self, $table, $row, $value) = @_;
    return $self->bus->write_register('Thermostat', $table, $row, $value, {src => $self->emulated_src});
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/CarBus/SAM.pm t/sam-emulator.t
git commit -m "Add configurable emulated_src attribute to CarBus::SAM"
```

---

### Task 2: Add `_exception_reply` and fix `_handle_read`

Unknown register reads currently return `undef` (silently dropped). They must return an exception frame with code `0x04`.

**Files:**
- Modify: `lib/CarBus/SAM.pm` (update `_handle_read`, add `_exception_reply`)
- Modify: `t/carbus-develop.t:226-234`

- [ ] **Step 1: Write the failing test**

Update the unknown register read test in `t/carbus-develop.t` at line 226-234:

```perl
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
    is($exc_reply->struct->{reg_string}, 'FFFF', 'exception reply reg_string matches request');
    is(unpack("C", substr($exc_reply->struct->{payload_raw}, 3, 1)), 0x04, 'exception code is 0x04');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/carbus-develop.t`
Expected: FAIL — `handle_frame returns undef for unknown register read` assertion will fail because it now expects a defined value.

- [ ] **Step 3: Implement `_exception_reply` and update `_handle_read`**

In `lib/CarBus/SAM.pm`, add the `_exception_reply` method after `_handle_write`:

```perl
sub _exception_reply {
    my ($self, $frame, $code) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    return CarBus::Frame->new(
        src     => $self->emulated_src,
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'exception',
        payload_raw => pack("C*", 0, $table, $row, $code),
    );
}
```

Then replace `_handle_read` with:

```perl
sub _handle_read {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));

    my $handler = $self->handlers->{$reg_key}->{read};
    my $data = $handler ? $handler->() : $self->get_register($reg_key);

    if (defined $data) {
        return CarBus::Frame->new(
            src     => $self->emulated_src,
            src_bus => $fs->{dst_bus},
            dst     => $fs->{src},
            dst_bus => $fs->{src_bus},
            cmd     => 'reply',
            payload_raw => pack("C*", 0, $table, $row) . $data,
        );
    }

    return $self->_exception_reply($frame, 0x04);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/CarBus/SAM.pm t/carbus-develop.t
git commit -m "Return exception frame for unknown register reads in SAM emulator"
```

---

### Task 3: Add `set_zone_setpoint` domain method to CarBus::SAM

This is the domain-level method that external callers (the infinitude app) use. It composes the existing state and bus methods.

**Files:**
- Modify: `lib/CarBus/SAM.pm`
- Modify: `t/sam-emulator.t`

- [ ] **Step 1: Write the failing tests**

Append to `t/sam-emulator.t` before `done_testing()`:

```perl
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/sam-emulator.t`
Expected: FAIL — `Can't locate object method "set_zone_setpoint"`.

- [ ] **Step 3: Implement `set_zone_setpoint`**

Add to `lib/CarBus/SAM.pm` after the existing `write_thermostat` method:

```perl
# Domain method: set heat and cool setpoints for a zone
sub set_zone_setpoint {
    my ($self, $zone, $heat_sp, $cool_sp) = @_;

    my $reg_key = '3b03';
    my $parser = CarBus::Frame::subparser('3B03');
    my $data = $self->get_register($reg_key);
    return unless defined $data;

    my $parsed = $parser->parse($data);

    # Zone indices are 1-based in the API, 0-based in the array
    my $idx = $zone - 1;
    $parsed->{heat_setpoint}[$idx] = $heat_sp if defined $heat_sp;
    $parsed->{cool_setpoint}[$idx] = $cool_sp if defined $cool_sp;

    my $new_data = $parser->build($parsed);
    $self->set_register($reg_key, $new_data);

    # Write to thermostat on bus using emulated_src
    $self->write_thermostat(0x3B, 0x03, $new_data);

    # Notify thermostat of the change
    $self->notify_change($reg_key);

    return 1;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/CarBus/SAM.pm t/sam-emulator.t
git commit -m "Add set_zone_setpoint domain method to CarBus::SAM"
```

---

### Task 4: Wire `EMULATE_SAM` into infinitude

Add env var, SAM initialization with `emulated_src => 'SAM'`, and frame interception in the websocket loop.

**Files:**
- Modify: `infinitude`

- [ ] **Step 1: Add env var configuration**

In `infinitude`, after the existing env var block (around line 52, after the `PASS_REQS` line), add:

```perl
$config->{emulate_sam} = $ENV{EMULATE_SAM} || $config->{emulate_sam};
```

- [ ] **Step 2: Initialize SAM in `serial_init()`**

After the line `$carbus = CarBus->new($handle) if $handle;` (line 82), add:

```perl
    if ($handle and $config->{emulate_sam}) {
        require CarBus::SAM;
        $sam = CarBus::SAM->new(bus => $carbus, emulated_src => 'SAM');
        $sam->initialize_defaults();
        warn "SAM emulation enabled\n";
    }
```

- [ ] **Step 3: Intercept SAM frames in websocket loop**

In the websocket handler's recurring loop, after `if (my $frame = $carbus->get_frame) { return if (!$frame or !$frame->struct->{cmd});` (line 425), add:

```perl
            if ($sam and my $reply = $sam->handle_frame($frame)) {
                $carbus->write($reply);
            }
```

- [ ] **Step 4: Run tests to verify nothing broke**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/`
Expected: All tests PASS. (No new tests here — the env var path is integration-level, tested by running the app with `EMULATE_SAM=1`.)

- [ ] **Step 5: Commit**

```bash
git add infinitude
git commit -m "Wire EMULATE_SAM env var into infinitude for in-process SAM emulation"
```

---

### Task 5: Hook setpoint API to route through RS485

When a setpoint change comes via the existing API and `$sam` is active, route it through RS485 with XML fallback.

**Files:**
- Modify: `infinitude`

- [ ] **Step 1: Add RS485 hook to the activity setpoint handler**

In the `/api/:zone_id/activity/:activity_id` handler (around line 226), after the existing `$store->set(changes => 'true');` (line 242) and before the `last;` (line 243), add the RS485 routing:

```perl
				# Route setpoint changes through RS485 if SAM emulation is active
				if ($sam and (defined $c->req->param('htsp') or defined $c->req->param('clsp'))) {
				    my $heat = $c->req->param('htsp') // $activity->htsp->[0];
				    my $cool = $c->req->param('clsp') // $activity->clsp->[0];
				    eval { $sam->set_zone_setpoint($idx + 1, $heat + 0, $cool + 0) };
				    # If RS485 fails, we already updated XML cache above (fallback)
				}
```

- [ ] **Step 2: Run tests to verify nothing broke**

Run: `prove -I ~/perl5/lib/perl5 -I lib t/`
Expected: All tests PASS.

- [ ] **Step 3: Commit**

```bash
git add infinitude
git commit -m "Route setpoint API changes through RS485 when SAM emulation is active"
```

---

### Task 6: Update CLAUDE.md with new configuration

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add EMULATE_SAM to the configuration table**

Add a row to the Configuration table in `CLAUDE.md`:

```markdown
| `EMULATE_SAM` | Enable SAM emulation on RS485 bus (1 = enabled) |
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Document EMULATE_SAM configuration variable"
```
