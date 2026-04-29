---
column: Done
---

# aon: Monitor exits too quickly despite persistent:true
## Problem

After `aon launch <role>`, starting monitor via SessionStart hook exits after ~30s-1min despite:
- `persistent: true`
- `timeout_ms: 3600000` (1 hour)

Monitor subscribes to subjects correctly, then nats sub processes exit cleanly.

## Expected Behavior

Monitor should stay alive for full 1-hour timeout, waiting for events on subscribed subjects.

## Investigation

- [ ] Check if nats sub has internal timeout
- [ ] Check if Claude Code Monitor tool has undocumented timeout
- [ ] Check if NATS server closing connections (e.g. idle timeout)
- [ ] Check if process group signal being sent

## Impact

Agents lose realtime event stream after ~1min, must poll instead (anti-pattern).
