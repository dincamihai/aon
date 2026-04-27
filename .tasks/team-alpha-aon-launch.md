---
column: Backlog
created: 2026-04-27
order: 241
priority: high
parent: team-alpha-meta-aon-cli
---

# Card 241 — `aon launch <role>` — unified agent entrypoint

Today operator + joiner have separate launch paths:

- **Operator** (running as own role): hand-export
  `TEAM_ALPHA_ROLE/NATS_URL/CREDS`, run `bash
  $ENGINE/scripts/hooks/install.sh`, `cd team-repo && claude`,
  then in-session `bash $ENGINE/scripts/onboard.sh <role>`.
- **Joiner**: `bash $ENGINE/scripts/join.sh <role> <work-repo>`
  → `cd <work-repo> && claude`.

Ten-step block at best. One CLI:

```bash
aon launch <role> [<work-repo>]
```

## Behavior

1. Read `aon.toml` for NATS URL + KV bucket.
2. Check `~/.team-alpha/<role>.password` exists; else `aon creds <role>`
   (Card 242) populates it from `nats/.passwords`.
3. Verify NATS handshake as `<role>` (1s timeout) — bail with
   actionable error if fails.
4. Determine `<work-repo>`: positional arg, else
   `aon.toml [repos] default` resolved against
   `[repos] repos_root`, else CWD.
5. Run `aon hooks install` (Card 243) into the work repo.
6. Stamp `.claude/settings.json` + `.mcp.json` into work repo
   with env baked in (matches current `join.sh` behavior).
7. Symlink `<work-repo>/CLAUDE.md` → engine/team prompt.
8. `cd <work-repo>` and `exec claude`.

`aon onboard <role>` for the in-session "post handshake + seed
load + print monitors" block from `scripts/onboard.sh` — fold
that into `launch` so first turn auto-runs.

## Acceptance

- Fresh box (engine + team repo cloned, password received) +
  one `aon launch mihai` → claude session starts with monitors
  printed + handshake on `agents.mihai.events`.
- Re-running re-uses cached creds; no re-prompt.
- Bad password → exits non-zero before claude launches.

## Why

Cuts ~10 lines of operator/joiner boilerplate to one. The trial
workflow becomes `aon launch mihai`. Joiner workflow becomes `aon
launch vahid ~/Repos/team-poc-work`.
