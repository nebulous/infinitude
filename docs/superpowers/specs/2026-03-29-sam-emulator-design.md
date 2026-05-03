# SAM Emulator Design

**Goal:** Create an emulated SAM that is indistinguishable from a real SAM on the RS485/CarBus, allowing Infinitude to control a Carrier thermostat without cloud services.

## Success Criteria

The thermostat interacts with the emulated SAM exactly as it would with a physical SAM. From the thermostat's perspective, there is no difference.

## Architecture

```
┌─────────────┐     RS485/CarBus      ┌─────────────────┐
│ Thermostat  │◄────────────────────►│  SAM Emulator   │
└─────────────┘     (polls/replies)  │  (standalone)   │
                                      └────────▲────────┘
                                               │ writes
                                      ┌────────┴────────┐
                                      │   Infinitude    │
                                      │ (sends CarBus   │
                                      │  write frames)  │
                                      └─────────────────┘
```

**Key principle:** The emulator is a logically independent device on the bus. It communicates with Infinitude only via CarBus frames, not shared memory or internal APIs.

## Protocol Model

**Note:** The master/slave relationship, frame direction, and who-writes-what-where are subject to change based on observations of the physical SAM. The following is our current hypothesis.

The thermostat polls the SAM; the SAM replies with current state:

```
Thermostat -> read request -> SAM
SAM -> reply with current state -> Thermostat
```

The SAM does not push changes. It simply has the correct answer ready when polled.

When Infinitude wants to change a setting:
```
Infinitude -> write to SAM emulator -> SAM updates state
Next thermostat poll -> SAM replies with new state
```

## Components

### CarBus::SAM (Enhanced)

The existing `CarBus::SAM` module will be enhanced with:

**New attributes:**
```perl
has store => (is => 'ro', default => sub {
    CHI->new(driver => 'File', root_dir => 'state/sam-emulator')
});
```

**New methods:**
```perl
sub initialize_defaults {
    # Populate store with default register values if empty
}

sub registers {
    # Returns store->get('registers') // {}
}

sub set_register {
    my ($self, $key, $value) = @_;
    my $regs = $self->registers;
    $regs->{$key} = $value;
    $self->store->set('registers', $regs);
}
```

**Modified methods:**
- `_handle_read` - reads from `store->get('registers')`
- `_handle_write` - writes via `set_register()` (saves immediately)

### sam-emulator (Script)

Standalone runner script:

```perl
my $bus = CarBus->new($io_handle);  # Serial or network
my $sam = CarBus::SAM->new(bus => $bus);
$sam->initialize_defaults();

while (1) {
    if (my $frame = $bus->get_frame()) {
        if (my $reply = $sam->handle_frame($frame)) {
            $bus->write($reply);
        }
    }
}
```

## Registers (Initial Scope)

| Register | Direction | Purpose |
|----------|-----------|---------|
| `0104` | read | Device info (model, serial, software) |
| `030D` | read | SAM status bytes |
| `3B02` | read | System state (mode, temps, humidity, time) |
| `3B03` | read/write | Zone settings (setpoints, fan, hold, names) |

**Future expansion:** `3B04` (vacation), `3B05` (accessories), `3B06` (dealer/config)

## Default Values

On first run (`initialize_defaults()`):

- **0104 (device_info):**
  - device: "SYSTEM ACCESS MODULE"
  - model: "INFINITUDE01"
  - software: version string
  - serial: generated or configured

- **030D (sam_status):**
  - Static bytes: 61, 62, 63, 0, 0, 0, 0 (observed from real SAM)

- **3B02 (system_state):**
  - mode: off
  - temperatures: 70°F
  - humidity: 50%
  - outdoor temp: from config or last known

- **3B03 (zone_settings):**
  - heat_setpoint: 68°F
  - cool_setpoint: 76°F
  - fan_mode: auto
  - hold: off

## Error Handling

- **Unknown register reads:** Observe real SAM behavior (likely exception frame 0x15)
- **Invalid write data:** Log warning, send exception reply, don't update state
- **Concurrent access:** CHI handles locking internally

## Learning from Physical SAM

Before implementing unknown behaviors, observe the physical SAM:

1. Bridge real SAM to bus monitor
2. Log SAM queries/replies for target register
3. Implement based on observations
4. Validate against captured traffic

**Physical SAM limitations to be aware of:**
- ASCII interface is unreliable (NAKs, retries needed)
- Network bridge won't loop back frames we send
- Use ASCII probing only for learning, not as product feature

## Deployment Options

Designed for flexibility:

1. **Standalone process** (initial implementation)
   - Runs independently via `sam-emulator` script
   - Can be on same machine or different machine

2. **Embedded in Infinitude** (future)
   - Same modules, different runner
   - Runs as thread/fork within main app
   - Still communicates via CarBus, not shared memory

## Out of Scope (for now)

- ASCII protocol server (secondary goal, may never be needed)
- Full register support (3B04-3B06)
- Embedded mode in Infinitude
- Shared state optimization between emulator and Infinitude

## File Changes

| File | Change |
|------|--------|
| `lib/CarBus/SAM.pm` | Add store, initialize_defaults, modify handlers |
| `sam-emulator` | Update to use enhanced CarBus::SAM |
| `state/sam-emulator/` | New directory for CHI cache |

## Implementation Order

1. Add `store` attribute and `initialize_defaults()` to CarBus::SAM
2. Modify `_handle_read` and `_handle_write` to use store
3. Update `sam-emulator` script
4. Test with minimal registers (0104, 030D, 3B02, 3B03)
5. Observe real SAM for unknown register behavior
6. Expand register support as needed
