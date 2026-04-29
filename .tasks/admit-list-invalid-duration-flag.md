---
column: Done
priority: high
created: 2026-04-29
source: tim review (D1) on 4d5911b..62dc26d
---

# `admit list` always returns empty: `nats sub --wait 3000` is invalid duration

Commit `3bb3312` (`feat(aon): add cmd_admit_list for waiting-room admin`).

`bin/aon:2623` — `nats sub ... --wait 3000` fails with `invalid duration` on nats CLI 0.3.2; duration flags require a unit suffix. The trailing `|| true` swallows the error, `raw` stays empty, function always prints "no pending requests". `cmd_admit_list` is **completely non-functional**.

## Fix

```bash
# current (broken)
nats ... sub "$waiting_room_subj" --count 100 --wait 3000 --raw 2>/dev/null

# fix
nats ... sub "$waiting_room_subj" --count 100 --wait 3s --raw 2>/dev/null
```

## Acceptance

1. `aon admit list` actually drains and prints pending requests.
2. Smoke test in `scripts/nsc-smoke/` covers an admit-list call against a primed waiting-room subject.

## Why high

Half of the waiting-room admin flow is dead until this lands. Combined with D2 (anon deny-pub) the entire flow is broken end-to-end.
