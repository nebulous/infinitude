# SAM Emulator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance CarBus::SAM with persistent state storage and update sam-emulator script to use it.

**Architecture:** Add CHI-backed store to CarBus::SAM for persistent register storage. The store holds a 'registers' key containing all register data. Writes persist immediately via set_register(). The sam-emulator script is simplified to use initialize_defaults() instead of manual setup.

**Tech Stack:** Perl, Moo, CHI (file-based cache), CarBus::Frame, Data::ParseBinary

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/CarBus/SAM.pm` | SAM emulation with persistent state storage |
| `sam-emulator` | Standalone runner script |
| `t/sam-emulator.t` | Tests for store and register handling |

---

### Task 1: Add CHI Dependency

**Files:**
- Modify: `cpanfile`

- [ ] **Step 1: Verify CHI is already in dependencies**

Run: `grep -i CHI cpanfile`
Expected: CHI should already be listed (used by infinitude)

- [ ] **Step 2: If not present, add CHI to cpanfile**

```perl
requires 'CHI';
```

- [ ] **Step 3: Commit if changed**

```bash
git add cpanfile
git commit -m "Add CHI dependency for SAM emulator state storage"
```

---

### Task 2: Add Store Attribute to CarBus::SAM

**Files:**
- Modify: `lib/CarBus/SAM.pm` (lines 1-12)

- [ ] **Step 1: Add CHI import and store attribute**

Add `use CHI;` after the other imports and add the `store` attribute after the existing attributes. The new attribute section should look like:

```perl
package CarBus::SAM;
use strict;
use warnings;
use feature ':5.10';
use Moo;
use Data::ParseBinary;
use CarBus::Frame;
use CHI;

has bus => (is => 'ro', required => 1);
has store => (is => 'ro', default => sub {
    CHI->new(driver => 'File', root_dir => 'state/sam-emulator', depth => 0)
});
has handlers => (is => 'ro', default => sub { {} });
```

Note: Remove the `has registers => ...` line - it will be replaced by the `registers()` method in Task 3.

- [ ] **Step 2: Verify module still compiles**

Run: `perl -I lib -c lib/CarBus/SAM.pm`
Expected: `lib/CarBus/SAM.pm syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/CarBus/SAM.pm
git commit -m "Add CHI store attribute to CarBus::SAM"
```

---

### Task 3: Add Register Accessor Methods

**Files:**
- Modify: `lib/CarBus/SAM.pm` (add after store attribute, around line 14)

- [ ] **Step 1: Add registers() and set_register() methods**

Add these methods after the attribute definitions, before the register parser comments:

```perl
# Register storage - backed by CHI store
sub registers {
    my $self = shift;
    return $self->store->get('registers') // {};
}

sub set_register {
    my ($self, $key, $value) = @_;
    my $regs = $self->registers;
    $regs->{$key} = $value;
    $self->store->set('registers', $regs);
}

sub get_register {
    my ($self, $key) = @_;
    return $self->registers->{$key};
}
```

- [ ] **Step 2: Verify module compiles**

Run: `perl -I lib -c lib/CarBus/SAM.pm`
Expected: `lib/CarBus/SAM.pm syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/CarBus/SAM.pm
git commit -m "Add registers(), set_register(), get_register() methods to CarBus::SAM"
```

---

### Task 4: Update _handle_read to Use Store

**Files:**
- Modify: `lib/CarBus/SAM.pm` (lines 174-195, the `_handle_read` method)

- [ ] **Step 1: Replace $self->registers->{$reg_key} with $self->get_register($reg_key)**

The updated `_handle_read` method should be:

```perl
sub _handle_read {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $reg_key = sprintf("%02X%02X", $table, $row);

    # Try uppercase first (handler key), then lowercase (reg_string style)
    my $handler = $self->handlers->{$reg_key}->{read} // $self->handlers->{lc($reg_key)}->{read};
    my $data = $handler ? $handler->() : ($self->get_register($reg_key) // $self->get_register(lc($reg_key)));

    return unless defined $data;

    # Build reply frame
    return CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => pack("C*", 0, $table, $row) . $data,
    );
}
```

- [ ] **Step 2: Verify module compiles**

Run: `perl -I lib -c lib/CarBus/SAM.pm`
Expected: `lib/CarBus/SAM.pm syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/CarBus/SAM.pm
git commit -m "Update _handle_read to use get_register() for store-backed state"
```

---

### Task 5: Update _handle_write to Use Store

**Files:**
- Modify: `lib/CarBus/SAM.pm` (lines 197-222, the `_handle_write` method)

- [ ] **Step 1: Replace direct hash assignment with set_register() calls**

The updated `_handle_write` method should be:

```perl
sub _handle_write {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $value = substr($fs->{payload_raw}, 3);
    my $reg_key = sprintf("%02X%02X", $table, $row);

    # Try uppercase first (handler key), then lowercase (reg_string style)
    my $handler = $self->handlers->{$reg_key}->{write} // $self->handlers->{lc($reg_key)}->{write};
    if ($handler) {
        $handler->($value);
    } else {
        $self->set_register($reg_key, $value);
        $self->set_register(lc($reg_key), $value);  # Store both cases for consistency
    }

    # Send ack reply
    return CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => $fs->{payload_raw},
    );
}
```

- [ ] **Step 2: Verify module compiles**

Run: `perl -I lib -c lib/CarBus/SAM.pm`
Expected: `lib/CarBus/SAM.pm syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/CarBus/SAM.pm
git commit -m "Update _handle_write to use set_register() for persistent state"
```

---

### Task 6: Add initialize_defaults Method

**Files:**
- Modify: `lib/CarBus/SAM.pm` (add after get_register method, around line 30)

- [ ] **Step 1: Add initialize_defaults() method**

Add this method after `get_register()`:

```perl
# Initialize default register values if store is empty
sub initialize_defaults {
    my $self = shift;

    # Skip if registers already exist
    return if $self->store->get('registers');

    # Get parsers for building register data
    my $device_info_parser = CarBus::Frame::subparser('0104');
    my $sam_status_parser = CarBus::Frame::subparser('030D');
    my $state_parser = CarBus::Frame::subparser('3B02');
    my $zones_parser = CarBus::Frame::subparser('3B03');

    # Register 0104 - Device info
    $self->set_register('0104', $device_info_parser->build({
        device    => 'SYSTEM ACCESS MODULE',
        location  => '',
        software  => 'infinitude',
        model     => 'INFINITUDE01',
        serial    => '000000000001',
        reference => 'infinitude-sam-emulator',
    }));

    # Register 030D - SAM status
    $self->set_register('030D', $sam_status_parser->build({
        val1 => 61, val2 => 62, val3 => 63,
        reserved1 => 0, reserved2 => 0, reserved3 => 0, reserved4 => 0,
    }));

    # Register 3B02 - System state
    $self->set_register('3B02', $state_parser->build({
        active_zones => 0x01,
        temperature => [(70) x 8],
        humidity => [(50) x 8],
        oat => 70,
        zones_unoccupied => {
            z1 => 0, z2 => 0, z3 => 0, z4 => 0,
            z5 => 0, z6 => 0, z7 => 0, z8 => 0,
        },
        stagmode => { stage => 0, mode => 'off' },
        weekday => 'Monday',
        minutes_since_midnight => 480,
        displayed_zone => 1,
    }));

    # Register 3B03 - Zone settings
    $self->set_register('3B03', $zones_parser->build({
        active_zones => 0x01,
        fan_mode => [(0) x 8],  # auto
        zones_holding => {
            z1 => 0, z2 => 0, z3 => 0, z4 => 0,
            z5 => 0, z6 => 0, z7 => 0, z8 => 0,
        },
        heat_setpoint => [(68) x 8],
        cool_setpoint => [(76) x 8],
        humidity_setpoint => [(50) x 8],
        speed_controlled_fan => 0,
        hold_timer => 0,
        hold_duration => [(0) x 8],
        zone_name => [map { "Zone $_\0" . ("\0" x (12 - length("Zone $_") - 1)) } 1..8],
    }));
}
```

- [ ] **Step 2: Verify module compiles**

Run: `perl -I lib -c lib/CarBus/SAM.pm`
Expected: `lib/CarBus/SAM.pm syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/CarBus/SAM.pm
git commit -m "Add initialize_defaults() method to CarBus::SAM"
```

---

### Task 7: Write Tests for Store and Register Methods

**Files:**
- Create: `t/sam-emulator.t`

- [ ] **Step 1: Create test file with basic tests**

```perl
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

# Test 4: Case insensitivity
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
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `prove -I lib t/sam-emulator.t`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add t/sam-emulator.t
git commit -m "Add tests for CarBus::SAM store and register methods"
```

---

### Task 8: Update sam-emulator Script

**Files:**
- Modify: `sam-emulator`

- [ ] **Step 1: Simplify setup_emulation() to use initialize_defaults()**

Replace the `setup_emulation()` function with a simpler version that just calls `initialize_defaults()`:

```perl
sub setup_emulation {
    my $sam = shift;
    $sam->initialize_defaults();
    say "  -> SAM defaults initialized";
}
```

- [ ] **Step 2: Update the SAM instance creation to not require bus for store**

The script already creates SAM with a bus. No changes needed there, but verify the flow works.

- [ ] **Step 3: Test the emulator starts**

Run: `perl -I lib -c sam-emulator`
Expected: `sam-emulator syntax OK`

- [ ] **Step 4: Commit**

```bash
git add sam-emulator
git commit -m "Simplify sam-emulator to use initialize_defaults()"
```

---

### Task 9: Create State Directory

**Files:**
- Create: `state/sam-emulator/.gitkeep`

- [ ] **Step 1: Create directory and .gitkeep**

```bash
mkdir -p state/sam-emulator
touch state/sam-emulator/.gitkeep
```

- [ ] **Step 2: Ensure state/ is in .gitignore**

Check if `state/` is already in .gitignore. If not, add it:

```bash
grep -q "^state/" .gitignore || echo "state/" >> .gitignore
```

- [ ] **Step 3: Commit .gitkeep only (not state contents)**

```bash
git add state/sam-emulator/.gitkeep .gitignore
git commit -m "Add state/sam-emulator directory for CHI cache storage"
```

---

### Task 10: Integration Test

**Files:**
- None (manual testing)

- [ ] **Step 1: Run the full test suite**

Run: `prove -I lib t/`
Expected: All tests pass

- [ ] **Step 2: Manual test with network bridge (if available)**

```bash
./sam-emulator --serial_socket 192.168.1.23:23 --emulate
```

Observe that:
- SAM defaults are initialized on first run
- State persists across restarts
- Frames are handled correctly

- [ ] **Step 3: Verify state directory contains cache files**

Run: `ls -la state/sam-emulator/`
Expected: CHI cache files present after running emulator

---

## Summary

After completing this plan:

1. `CarBus::SAM` will have persistent state storage via CHI
2. `sam-emulator` will use `initialize_defaults()` for clean startup
3. State persists across emulator restarts
4. Tests verify the store and register functionality

Next steps (future work):
- Observe real SAM behavior for unknown register handling
- Add remaining registers (3B04, 3B05, 3B06)
- Test with real thermostat on bus
