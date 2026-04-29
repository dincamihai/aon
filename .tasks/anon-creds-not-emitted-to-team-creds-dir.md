---
column: Done
priority: high
created: 2026-04-29
source: rona exploratory (Bug 2) on 4d5911b..62dc26d
---

# `anon.creds` is never emitted to `~/.aon/teams/<team>/creds/` — `aon connect` cannot find it

`bin/_aon-lib.sh` — `_aon_nsc_ensure_user` creates the `anon` NSC user but does **not** call `_aon_nsc_emit_creds` for it. The creds land only at the nsc internal location:

```
~/.aon/nsc/data/nats/nsc/keys/creds/aon-op/<team>/anon.creds
```

But `cmd_connect` looks at `$(_aon_team_creds_dir <team>)/anon.creds`. File not found → connect fails before NATS handshake.

This is the root cause of the footgun captured in `aon-connect-detect-missing-anon-creds.md` — fix this and the detection card becomes redundant.

## Fix

After creating anon user in `_aon_nsc_ensure_user`, emit creds the same way as every other role:

```sh
_aon_nsc_emit_creds anon
```

## Acceptance

1. After `aon auth render` for a team that includes anon, `~/.aon/teams/<team>/creds/anon.creds` exists with chmod 600.
2. `aon connect <team>` finds the creds without manual copying.
3. Smoke test in `scripts/nsc-smoke/` includes a fresh-team → anon-connect path.
