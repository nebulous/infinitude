# SAM Comparator Structured Logging

**Date:** 2026-03-31
**Status:** Approved

## Goal

Replace all `sam-comparator` STDOUT output with JSONL (JSON Lines) so that all-day capture logs can be piped to a file and later ingested by Claude to analyze SAM behavior and improve the emulator.

## Approach

Every bus frame produces one JSONL line. Comparison verdicts, learning events, ASCII stimulation, and periodic stats are additional event types. No human-readable output — pure structured JSONL to STDOUT, piped to file at runtime.

## Event Schema

All lines share an envelope:

```json
{
  "ts": "2026-03-31T14:23:01.432Z",
  "elapsed": 1234.567,
  "event": "<type>",
  ...
}
```

- `ts` — ISO 8601 with milliseconds, UTC
- `elapsed` — seconds since script start (float, from Time::HiRes)
- `event` — one of: `startup`, `frame`, `comparison`, `learn`, `ascii`, `stats`, `shutdown`

### startup

Emitted once at launch. Contains config and initial emulator state.

```json
{
  "event": "startup",
  "ts": "...",
  "elapsed": 0,
  "config": { "network_bridge": "...", "serial_sam": "...", "clone": false, "ascii_enabled": true, ... },
  "known_registers": ["0104", "0202", "030D", "3B02", ...],
  "emulator_defaults_loaded": true
}
```

### frame

One per bus frame. The primary data source.

```json
{
  "event": "frame",
  "ts": "...",
  "elapsed": 100.5,
  "bus": "NET",
  "src": "Thermostat",
  "dst": "SAM",
  "cmd": "read",
  "reg": "3B02",
  "reg_name": "sam_state(3B02)",
  "valid": true,
  "hex": "200192010300000b003003eb8a",
  "payload_hex": "03000b003003eb",
  "payload": { "active_zones": 1, "temperatures": [...] }
}
```

- `bus` — bridge source identifier (NET or serial device name)
- `payload` — parsed struct if subparser exists, omitted if not
- `payload_hex` — always present for raw reconstructability

### comparison

Emitted when a real SAM response is matched to a pending emulator query.

```json
{
  "event": "comparison",
  "ts": "...",
  "elapsed": 100.6,
  "reg": "3B02",
  "reg_name": "sam_state(3B02)",
  "verdict": "match|gap|mismatch",
  "real_hex": "03000b003003eb",
  "emu_hex": "03000b003003eb",
  "real_payload": { ... },
  "emu_payload": { ... }
}
```

Three verdicts:
- `match` — byte-identical payloads
- `mismatch` — different payloads, both included for diff
- `gap` — emulator had no response at all (no `emu_*` fields)

### learn

New register captured from real SAM that emulator didn't know.

```json
{
  "event": "learn",
  "ts": "...",
  "elapsed": 200.3,
  "reg": "3B05",
  "reg_name": "sam_accessories(3B05)",
  "bytes": 42
}
```

### ascii

ASCII command lifecycle events. `phase` is one of `send`, `response`, `timeout`.

```json
{"event": "ascii", "ts": "...", "elapsed": 300.1, "phase": "send", "command": "S1Z1FAN!AUTO", "attempt": 3, "idle_ms": 120}
{"event": "ascii", "ts": "...", "elapsed": 300.4, "phase": "response", "attempt": 3, "response": "ACK", "latency_ms": 234}
{"event": "ascii", "ts": "...", "elapsed": 308.1, "phase": "timeout", "attempt": 3}
```

### stats

Periodic snapshot, replaces the human-readable coverage report. Default every 120s.

```json
{
  "event": "stats",
  "ts": "...",
  "elapsed": 7200.0,
  "total_frames": 42000,
  "sam_queries": 380,
  "comparisons": 375,
  "matches": 340,
  "mismatches": 35,
  "emulator_gaps": 5,
  "learned_registers": 12,
  "register_coverage": {
    "3B02": {"real": 80, "emu": 80, "mismatches": 2},
    "0104": {"real": 5, "emu": 0, "mismatches": 0}
  },
  "known_registers": ["0104", "0202", "030D", "3B02", ...],
  "ascii": {"sent": 3, "ok": 1, "timeouts": 2}
}
```

### shutdown

Final statistics in END block.

```json
{
  "event": "shutdown",
  "ts": "...",
  "elapsed": 86400.0,
  "total_frames": 150000,
  "sam_queries": 1200,
  "comparisons": 1100,
  "matches": 1000,
  "mismatches": 100,
  "emulator_gaps": 5,
  "learned_registers": 15,
  "register_coverage": { ... },
  "known_registers": [ ... ]
}
```

## Implementation Notes

- Use `JSON` module (already imported in SAM.pm, add to sam-comparator)
- Use `POSIX::strftime` or `Time::HiRes` for ISO timestamps with milliseconds
- Replace all `say` calls with a `log_event($hashref)` helper that adds envelope fields and emits `encode_json`
- Remove `--verbose` and `--compare_only` flags (no longer meaningful with structured output)
- Keep all other flags and bridge/emulator logic unchanged
- `bus` field: use frame's `busname` attribute, shortened to "NET"/"SAM" for readability
- Estimated volume: ~2-5 KB/sec, ~200-400 MB/day uncompressed

## Removed Flags

- `--verbose` — all frames are always logged
- `--compare_only` — all events are always emitted

## Runtime Usage

```bash
perl -I lib -I ~/perl5/lib/perl5 sam-comparator \
  | tee sam-comparator-$(date +%Y%m%d-%H%M%S).jsonl
```

Or with `nohup` for all-day runs:

```bash
nohup perl -I lib -I ~/perl5/lib/perl5 sam-comparator 2>&1 \
  | tee sam-comparator-$(date +%Y%m%d-%H%M%S).jsonl &
```
