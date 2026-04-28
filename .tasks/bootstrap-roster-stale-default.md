---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 46
priority: normal
parent: nsc-jwt-migration
---

**Shipped** in 2fcdbf4 — `bootstrap.sh` fails fast on missing
`AON_ROSTER` + `AON_KV_BUCKET` with directives pointing to
`aon resolve-env` / `aon bootstrap`. `cmd_resolve_env` reads
roster from `aon.toml` `[roles]` and exports `AON_ROSTER`.



# `scripts/bootstrap.sh`: stale default AON_ROSTER fallback

`scripts/bootstrap.sh:42` falls back to the prototype team-alpha
roster when `AON_ROSTER` is unset:

```bash
AON_ROSTER="${AON_ROSTER:-maya raj lin sam diego priya}"
```

Two problems:

1. **Names are obsolete** — the engine renamed team_alpha → aon
   (commit d54f794). Any caller that forgets to set `AON_ROSTER`
   will silently bootstrap a stream/KV state for ghost roles that
   don't exist in the team. Wastes resources, confuses operators.

2. **Silent fallback is wrong shape** — the substrate is per-team
   now. Roster must come from the team's `aon.toml`, not a hard-coded
   constant. Forgetting to set the env should fail loudly, not pick
   a default that "works" but for wrong roles.

## Fix

- Replace the fallback with a fail-fast check:
  ```bash
  : "${AON_ROSTER:?AON_ROSTER required (whitespace-separated role names; usually exported by 'aon resolve-env' from aon.toml)}"
  ```
- `aon resolve-env` should already export `AON_ROSTER` — verify and
  add if missing.
- Update bootstrap.sh comment to reflect "no fallback, read from
  aon.toml via aon resolve-env".

## Acceptance

- Running bootstrap.sh without `AON_ROSTER` exits non-zero with a
  clear error mentioning `aon resolve-env`.
- `aon resolve-env` exports `AON_ROSTER` from `aon.toml` `[roles]`.
- nsc-smoke Phase C still passes (it sets `AON_ROSTER` explicitly,
  so unaffected).

## Out of scope

- Reading aon.toml directly from bootstrap.sh (keep the contract
  that `aon resolve-env` is the single resolver).
