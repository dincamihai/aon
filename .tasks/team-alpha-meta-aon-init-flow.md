---
column: InProgress
created: 2026-04-27
order: 238
priority: medium
parent: team-alpha-team-portability
depends_on: team-alpha-meta-engine-vs-team-split
---

> **Status (2026-04-27, slice 4 partial):** `aon bootstrap`
> shipped. Reads aon.toml roster + nats/.passwords + nats config,
> exports `AON_ROSTER` + `AON_KV_BUCKET` + `NATS_*` env, calls
> `$AON_ENGINE_DIR/scripts/bootstrap.sh`.
>
> `scripts/bootstrap.sh` parameterized: `AON_ROSTER` (default
> = sim 6-role list) drives A2A_TASKS subjects + KV roster JSON +
> per-role agent.<role>.load seeds. `AON_KV_BUCKET` (default
> team-state) replaces the hardcoded bucket name.
>
> Smoke green: throwaway dir → `aon init` + .passwords reuse →
> `aon bootstrap` → 7 streams + KV + 6 agent.<role>.load seeds
> against the live NATS. Idempotent.
>
> Pending: full end-to-end docs walkthrough + `aon doctor` checks
> for NATS reachability post-bootstrap. Card stays InProgress
> until Card 237 (engine/team split) lands — cross-repo invocation
> path needs validation when scripts/bootstrap.sh moves to the
> engine and the team repo is purely declarative.

# Card 238 — Meta: `aon init` end-to-end flow (5-minute new-team bring-up)

Goal: a brand-new operator can stand up a working team in 5 minutes.

```bash
# install engine once
pipx install git+https://github.com/dincamihai/ai-over-nats     # or: brew tap …

# new team repo
mkdir -p ~/Repos/team-foo-aon && cd $_ && git init
aon init
# answers prompts: team name, NATS URL (default localhost), default repos root,
# initial roster (interactive, can add more later via `aon add-role`)
# writes: aon.toml, .tasks/, agents/, agent-prompts/, hooks/, nats/auth.conf.example,
#         README.md (template-rendered), .claude/settings.json, .mcp.json
aon auth set-passwords        # generates random pw, writes nats/auth.conf + .passwords
docker compose -f $(aon engine path)/docker-compose.yml up -d nats
aon bootstrap                  # streams + KV
aon doctor                     # green ✓
git add -A && git commit -m "init team-foo"
gh repo create --private --source=. --push
```

After this, the team repo is a normal git repo. Operator distributes
NATS URL + role passwords out-of-band; joiners run `aon join <role>
<work-repo>`.

## Deliverables

- Interactive `aon init` (or `--non-interactive --config`) that walks
  the operator through team creation.
- `aon bootstrap` subcommand wraps the existing `scripts/bootstrap.sh`
  but pulls config from aon.toml.
- `aon engine path` — prints the location of the engine (so docker
  compose etc. find it without hard-coded paths).
- `docs/aon-init-walkthrough.md` — 5-minute operator runbook.

## Acceptance

- A fresh empty directory + the commands above produce a working
  team session: NATS up, KV seeded, mihai joins, claude launches,
  agent posts handshake on `agents.mihai.events`.
- `aon doctor` green at every step.
- A second team (different name, different roster) created via the
  same flow does not collide with the first.

## Reference

`~/Repos/ai-fleet-harness/ai-fleet init` ships exactly this shape.
Use it as the spec; rename harness-specific bits.
