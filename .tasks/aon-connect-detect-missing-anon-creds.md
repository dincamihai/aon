---
column: Backlog
priority: low
created: 2026-04-29
source: joana audit (Other Notes) on 4d5911b..62dc26d
---

# `aon connect` should detect missing `anon.creds` and tell operator to run `aon auth render`

Commit `db3b3f6` (`feat(waiting-room): add anon user + fix age parsing`).

`aon connect` requires the team's `anon.creds` to be present. The file is materialized only by `aon auth render`. Operators who skip the render step (or run `aon connect` against a team that hasn't been re-rendered since the anon user was added) get a confusing low-level NATS error instead of "you need to run `aon auth render` on the admin side first".

## Fix

Before opening the NATS connection in `cmd_connect`, check for the expected anon creds path. If missing:

```
✗ anon credentials not found at <path>
  Admin must run `aon auth render && aon creds anon` (or distribute anon.creds out-of-band).
```

## Acceptance

1. Running `aon connect` on a team without `anon.creds` exits with a clear actionable message.
2. The error mentions the exact path checked and the command(s) the admin needs to run.
3. `aon doctor` surfaces the same warning when `anon.creds` is missing for any rostered team.
