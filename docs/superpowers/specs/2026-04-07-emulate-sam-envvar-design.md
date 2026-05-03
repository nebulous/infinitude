# EMULATE_SAM: RS485 Thermostat Control

## Summary

Enable infinitude to control the thermostat via RS485 (ABCD bus) instead of the Carrier web service emulation path. When `EMULATE_SAM` is set and serial is connected, infinitude acts as a SAM on the bus and routes setpoint changes through RS485 with XML fallback.

## Motivation

Currently infinitude controls the thermostat by intercepting HTTP requests between the thermostat and Carrier's cloud. RS485 control provides a local-only path that doesn't depend on the thermostat's network connection or Carrier's servers. This also enables control for setups where the thermostat isn't connected to the internet.

The majority of users control infinitude via Home Assistant, which calls the existing API. This change is transparent to those integrations — the same API calls work, but when RS485 is available they're written directly to the bus.

## POC Scope

Temperature setpoint changes via the existing API. The full vision is parity with web-service control (schedules, profiles, holds, etc.), but the POC validates the control path with the most common operation.

## Architecture

### Separation of Concerns

```
infinitude app        →  $sam->set_zone_setpoint($zone, 70, 76)   # domain method
                               ↓
CarBus::SAM           →  get/set_register('3b03', ...)             # internal state management
                         write_thermostat(0x3B, 0x03, $data)       # bus communication
                         notify_change('3b03')                      # thermostat acknowledgment
```

The infinitude app calls domain-level methods on SAM. It never touches registers or frames directly. All register addresses, frame formats, and bus protocol details are encapsulated within `CarBus::SAM`.

This pattern generalizes: future device modules (e.g. `CarBus::IndoorUnit`) would follow the same structure — domain methods on the outside, register/frame internals on the inside.

### CarBus::SAM Internal Layers

| Layer | Methods | Purpose |
|-------|---------|---------|
| **State** | `get_register`, `set_register`, `initialize_defaults` | CHI-backed register storage |
| **Bus** | `handle_frame`, `_handle_read`, `_handle_write`, `_exception_reply`, `write_thermostat`, `notify_change` | Frame processing and bus I/O |
| **Domain** (new) | `set_zone_setpoint`, `get_zone_setpoint`, ... | High-level control operations for external callers |

Domain methods compose state and bus methods. The infinitude app only calls domain methods.

## Design

### Configuration

Add `EMULATE_SAM` to the existing env var block in `infinitude`:

```perl
$config->{emulate_sam} = $ENV{EMULATE_SAM} || $config->{emulate_sam};
```

### Initialization

In `serial_init()`, after creating `$carbus`:

1. If `emulate_sam` is set, create a `CarBus::SAM` instance: `$sam = CarBus::SAM->new(bus => $carbus)`
2. Call `$sam->initialize_defaults()` to populate register data
3. Log that SAM emulation is active

The `$sam` variable lives at package scope alongside `$carbus` and `$handle`.

### Bus Emulation

In the `/serial` websocket handler's recurring loop, after `$carbus->get_frame()`:

1. Skip if `$sam` is not defined (emulation not enabled)
2. Call `my $reply = $sam->handle_frame($frame)`
3. If `$reply` is defined, write it to the bus: `$carbus->write($reply)`

This makes infinitude appear as a SAM to other devices on the bus.

### Setpoint Control Flow

When a setpoint change comes through the existing API (e.g. Home Assistant POST to update zone temperature):

1. If `$sam` is defined (RS485 + emulation active), call `$sam->set_zone_setpoint($zone, $heat_sp, $cool_sp)`
2. `set_zone_setpoint` internally: updates 3B03 register state, writes to thermostat on bus, triggers notification flow
3. If the RS485 write fails, fall back to the existing XML cache update path
4. If `$sam` is not defined, the existing XML-only path runs unchanged

The hook point is the existing setpoint API handler — no new endpoints needed.

### New CarBus::SAM Domain Method

```perl
sub set_zone_setpoint {
    my ($self, $zone, $heat_sp, $cool_sp) = @_;
    # $zone is 1-8

    # Get current 3B03 data, parse it, update setpoints for the zone,
    # rebuild the register, store it, write to thermostat, notify
}
```

### Exception Handling

When a device on the bus reads a register the emulator doesn't serve, the emulator must send an exception reply (not silently drop the frame). Observed in real traffic: `cmd=exception`, payload byte `0x04`.

Fix `_handle_read` in `CarBus::SAM`:

```perl
sub _handle_read {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));

    my $handler = $self->handlers->{$reg_key}->{read};
    my $data = $handler ? $handler->() : $self->get_register($reg_key);

    if (defined $data) {
        # Known register - reply with data
        return CarBus::Frame->new(
            src     => 'FakeSAM',
            src_bus => $fs->{dst_bus},
            dst     => $fs->{src},
            dst_bus => $fs->{src_bus},
            cmd     => 'reply',
            payload_raw => pack("C*", 0, $table, $row) . $data,
        );
    }

    # Unknown register - send exception reply
    return $self->_exception_reply($frame, 0x04);
}

sub _exception_reply {
    my ($self, $frame, $code) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    return CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'exception',
        payload_raw => pack("C*", 0, $table, $row, $code),
    );
}
```

### Source Address

`CarBus::SAM` has a configurable `emulated_src` attribute (default: `'FakeSAM'`). All reply frames and bus writes use this as the source address. When infinitude creates the SAM instance for real emulation, it passes `emulated_src => 'SAM'` (0x92). Existing tools (sam-comparator, etc.) keep the default FakeSAM (0x93) address for making arbitrary queries without being mistaken for the real SAM.

### Files Changed

| File | Change |
|------|--------|
| `lib/CarBus/SAM.pm` | Add `set_zone_setpoint` domain method |
| `infinitude` | Read env var, create SAM instance, intercept frames, route setpoint writes through RS485 |

No frontend changes. No new dependencies.

### Constraints

- Requires serial connection (`SERIAL_TTY` or `SERIAL_SOCKET`). If no serial bus, SAM instance is never created and XML path runs unchanged.
- ABCD bus emulation only — no RS-232 ASCII protocol handling.
- Restart required to change the setting (same as other env vars).
- POC only covers setpoint changes. Other controls (mode, fan, hold, schedules) follow the same pattern but are future work.
