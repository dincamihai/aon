---
column: InProgress
created: 2026-04-27
order: 233
priority: high
parent: team-alpha-team-portability
ref: ai-fleet-harness/ai-fleet
---

> **Status (2026-04-27, slice 1):** skeleton landed.
>
> Shipped subcommands:
> - `aon init` — bootstraps `aon.toml` + dir tree (.tasks, agents,
>   agent-prompts, hooks, nats).
> - `aon add-role NAME KIND DOMAIN` — appends role to roster.
>   Idempotent (re-adds detect existing entry).
> - `aon doctor` — validates aon.toml, dirs, deps (nats/jq/claude),
>   and lists the parsed roster.
> - `aon apparmor SUB` — delegates to existing `bin/team-alpha-apparmor`.
>
> Skeleton verified end-to-end: empty dir → `aon init` → `aon
> add-role vahid generalist python` → `aon doctor` reports 7 roles
> + green deps.
>
> Pending (later slices):
> - `aon bootstrap` (Card 238) — wraps scripts/bootstrap.sh from
>   aon.toml.
> - `aon prompts render` (Card 234) — fill templates with roster.
> - `aon auth render` (Card 235) — generate auth.conf + passwords.
> - `aon status`, `aon nudge` — `ai-fleet`-style observability.

# Card 233 — Meta: ship `aon` CLI (init / add-role / status / doctor / apparmor)

Mirror what `ai-fleet-harness` ships as the `ai-fleet` binary at the
repo root. Single Bash CLI, subcommand-shaped, no dependencies beyond
`bash`, `git`, `jq`, `nats`. Operator runs it from inside their
per-team repo to bootstrap, manage roster, sanity-check.

See `~/Repos/ai-fleet-harness/ai-fleet` for the reference shape.

## Subcommands (target)

| Cmd | Behavior |
|---|---|
| `aon init` | Bootstrap harness in the current repo. Reads `aon.toml` if present, else writes a default. Copies scripts + hooks from the engine into the per-team repo. Renders prompts from templates + roster (Card 234). |
| `aon add-role NAME [DOMAIN]` | Append role to roster + emit auth.conf block + render prompt. |
| `aon status` | Open PRs, InProgress cards, recent NATS events, fleet roster. |
| `aon nudge ROLE` | Publish a reminder event to a silent role. |
| `aon doctor` | Sanity-check: NATS reachable, creds in place, hooks installed, prompts rendered, mcp-server installed, repo aon.toml schema valid. |
| `aon apparmor SUB` | Subcommands: sync / show / reload / watch (Cards 228/229). |

## Deliverables

- `bin/aon` — Bash umbrella, sourcing helpers from `bin/_aon-lib.sh`.
- `bin/_aon-lib.sh` — config loader (`_load_config`), template renderer
  (`_render_template`), TOML parser (awk-based, no external dep).
- Update README to point users at `aon init` as the canonical entrypoint.

## Acceptance

- `aon init` in an empty repo writes `aon.toml`, creates `.tasks/`,
  `scripts/`, `hooks/`, `agent-prompts/`, copies the engine's scripts
  + hooks, renders prompts from templates, emits next-step instructions.
- `aon add-role mihai manager` updates `aon.toml` roster, emits an
  auth.conf user block, and renders `agent-prompts/mihai.md` from the
  manager template.
- `aon doctor` reports OK on a freshly init'd + bootstrapped repo.

## Why

Currently every team would fork ai-over-nats and hand-edit role names,
auth ACLs, prompts. The CLI inverts: engine is installable, per-team
repo holds *only* the team-specific config + cards. Removes hundreds
of lines of manual edits per onboarding.

## Reference

`~/Repos/ai-fleet-harness/ai-fleet` (~250 lines of bash). Steal
liberally — the shape is proven.
