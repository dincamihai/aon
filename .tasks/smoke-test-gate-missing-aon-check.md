---
column: Backlog
priority: low
created: 2026-04-29
source: rona exploratory (Bug 3) on 4d5911b..62dc26d
---

# `smoke_test_gate.sh` exits 0 when `aon` binary missing from PATH

`scripts/smoke_test_gate.sh` only checks `nats ping` exit code. Does not verify `aon` is on PATH. Running with `PATH=` still reports pass — gate is meaningless without `aon`.

## Fix

```sh
command -v aon >/dev/null 2>&1 || { echo "aon not on PATH"; exit 1; }
```

at the top of the gate, before the nats ping check.

## Acceptance

1. Gate exits non-zero when `aon` is missing.
2. Existing successful runs unaffected.
