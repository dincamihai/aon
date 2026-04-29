---
column: Backlog
priority: medium
created: 2026-04-29
source: tim review (D3) on 4d5911b..62dc26d
---

# `cmd_connect`: `nats req --wait 300000` — unknown flag, effective timeout 5s not 5min

Commit `32daffe` (`feat(aon): add cmd_connect for waiting-room joiner flow`).

`bin/aon:2770` — `nats req` has no `--wait` flag (only `--timeout`). The value `300000` is consumed as the body argument; the effective timeout falls back to the CLI default `--timeout 5s`. Comment says "5min timeout" but joiner actually times out in 5 seconds — far too short for an admin to notice + run `admit list` + approve.

## Fix

```bash
# current (broken)
nats ... req "$waiting_room_subj" --wait 300000 2>/dev/null

# fix
nats ... req "$waiting_room_subj" --timeout 300s 2>/dev/null
```

## Acceptance

1. Joiner waits up to 5 minutes for admin reply (matches comment + intent).
2. `--body` (or stdin) is set explicitly so positional argument doesn't get hijacked again.
3. Smoke test asserts joiner survives at least 30s without admin reply (without timing out).
