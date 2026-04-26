---
column: Backlog
created: 2026-04-26
order: 223
---

# Card 223 — Team portability: configurable team + role names

Today the substrate is hardcoded to "team-alpha" with five fixed
worker roles `{priya, raj, lin, sam, diego}` (+ maya simulation).
Other teams adopting this can't just clone — they have to rename
everything inline, which collapses upstream improvements.

Goal: when a new team starts using ai-over-nats, they configure
their team name + role names + role briefs once, then the
substrate is theirs. No code edits to the engine.

## Scope

Configurable at team-onboarding time:

- **Team name** (`team-alpha` → e.g. `team-saas`, `team-platform`)
  → flows into NATS account name, stream prefixes (or per-team
  streams), KV bucket name, hook env paths (`~/.team-saas/`),
  repo-internal references.
- **Role list** (5 names + their skill maps) — replaces
  hardcoded `{priya, raj, lin, sam, diego}`.
- **Per-role briefs** — markdown files generated from a template,
  edited by the team.

Not configurable (intentionally fixed across all teams):

- Subject taxonomy shape (`agents.<role>.inbox`,
  `board.tasks.<domain>.<state>`, `a2a.<role>.tasks.<id>.>`).
  Engine expects this layout; teams pick *what* fills the
  variables, not the shape.
- Lifecycle states (`submitted, working, completed, failed,
  canceled`).
- A2A protocol semantics.

## Configuration model

Single source of truth: `team.toml` at repo root. New file shipped
by the engine as `team.toml.example` with comments. Each team
copies + customizes once.

```toml
# team.toml — team-specific config (gitignored once customized)
name = "team-alpha"
nats_account = "team-alpha"
kv_bucket = "team-state"
stream_prefix = ""           # empty = global stream names; set
                              # if running shared NATS infra w/
                              # multiple teams.

[hub]
url_default = "wss://nats.team-alpha.example"

[[roles]]
name = "priya"
description = "Terraform / AWS specialist."
skills = [
  { id = "aws", tier = "primary" },
  { id = "terraform", tier = "primary" },
  { id = "python", tier = "growing" },
]

[[roles]]
name = "raj"
description = "Senior generalist."
# ...

# Optional: simulation roles, never seated in live sessions.
[[roles]]
name = "maya"
description = "Coordinator (simulation only)."
simulation_only = true
```

The engine reads `team.toml` and:
- generates `nats/auth.conf` from a template (stable structure,
  variable users + permissions per role).
- generates `agents/<role>.json` from each `[[roles]]` block.
- generates per-role brief stubs at
  `scripts/agent-prompts/<role>.md` if missing (team edits in
  place; engine never overwrites once customized).
- exports `$TEAM_NAME` everywhere code currently hardcodes
  `team-alpha` (`HOOK_ROLE` validator, `~/.<team>/` paths,
  KV bucket name, etc).

## What to parameterize (touch list)

- `nats/nats-server.conf` + `nats/auth.conf.example` — `account`
  name + the static parts of the user permission template.
- `nats/auth.conf` — fully generated from `team.toml`.
- `scripts/hooks/_lib.sh` — replace hardcoded
  `case maya|raj|...` with dynamic role list from
  `agents/*.json`. Replace `~/.team-alpha/` with
  `~/.${TEAM_NAME}/`.
- `scripts/onboard.sh` — `VALID_ROLES` from `agents/*.json`.
- `scripts/bootstrap.sh` — KV bucket name + stream names from
  `team.toml`.
- `scripts/join.sh` — read `team.toml` for the role list shown
  in usage; default NATS URL from `[hub]`.
- `scripts/agent-prompts/_common.md` — keep as-is; references
  generic concepts, not team specifics.
- `mcp-server/src/team_alpha_mcp/` — package rename to
  `substrate_mcp` or similar (drop `team_alpha`); read
  `$TEAM_NAME` at runtime for any subject-formatting needs.
- Docs (`MODEL.md`, `docs/team-session-runbook.md`,
  `docs/team-bootstrap-prompt.md`) — replace literal
  `team-alpha` with `<team>` placeholders or keep as the
  example, with a callout.

## Slices

### Slice 1 — `team.toml` + generators

- Add `team.toml.example` (committed) and `team.toml`
  (gitignored).
- Add `scripts/configure-team.sh` — reads `team.toml`,
  generates `nats/auth.conf`, `agents/<role>.json`,
  brief stubs.
- Idempotent: re-running adds new roles without clobbering
  customized briefs.

### Slice 2 — env-driven engine

- All hardcoded `team-alpha` strings in scripts replaced by
  `${TEAM_NAME:-$(toml-read team.toml name)}`.
- All hardcoded `~/.team-alpha/` paths replaced by
  `~/.${TEAM_NAME}/`.
- `_lib.sh` role list dynamic from `agents/*.json`.

### Slice 3 — MCP package rename

- `team_alpha_mcp` → `substrate_mcp` (or similar generic name).
- Read `TEAM_NAME` at runtime; subject-format functions take
  it as a parameter.
- `pyproject.toml` updated; entrypoint script renamed.
- Backwards-compat shim: keep `team_alpha_mcp` as a thin
  wrapper that warns "deprecated; use substrate_mcp".

### Slice 4 — multi-team docs

- Rewrite `docs/team-session-runbook.md` to use `<team>`
  placeholders.
- Add `docs/adopting-substrate.md` — what a new team does on
  day 1: clone, copy `team.toml.example`, edit, run
  `configure-team.sh`, customize briefs.
- Update `docs/team-bootstrap-prompt.md` to reference
  `team.toml` for the role list, not hardcoded.

### Slice 5 — multi-team substrate (optional, far future)

- Single NATS hub serving multiple `team-*` accounts side by
  side. Per-team isolated subject space + KV.
- Useful only when ai-over-nats has >2 adopters sharing infra.
- Probably never relevant; teams typically run their own hub.

## Migration path for team-alpha

1. Slice 1 lands: `team.toml.example` exists. team-alpha's own
   config is bootstrapped into a real `team.toml` (round-trips
   against current `agents/*.json` + `auth.conf`). Verify diff
   = 0 against committed state.
2. Slice 2 lands: scripts read from env / config. No behavior
   change for team-alpha (still picks up `team-alpha` from
   `team.toml`).
3. Slice 3 lands: MCP package rename. Update everyone's
   `.mcp.json` (single edit; join.sh re-stamp).
4. Slice 4 lands: docs generic. Done.
5. Test by spinning up a `team-bravo` config alongside (different
   roles, different account, same hub) — proves real isolation.

## Acceptance

- [ ] `cp team.toml.example team.toml`, edit name + roles, run
      `configure-team.sh`. Get a working substrate without any
      engine code edits.
- [ ] team-alpha's existing config bootstraps to byte-identical
      `agents/*.json` + `auth.conf` after slice 1 round-trip.
- [ ] A second team (`team-bravo`) configured in a clean clone
      runs end-to-end: bootstrap, join.sh, dispatch, complete,
      AUDIT.
- [ ] No hardcoded `team-alpha` or `priya|raj|lin|sam|diego` in
      scripts/, mcp-server/, hooks/. (grep clean.)
- [ ] Docs reference `<team>` / `<role>` placeholders with
      team-alpha as the running example.

## Out of scope

- A web UI for team configuration.
- Multi-team SaaS hosting model.
- Migrating existing team-alpha AUDIT history into a renamed
  account (start fresh on rename if unavoidable).

## Refs

- Card 220 — post-MVP delegate + SDK; orthogonal but the engine
  rename happens in the same era.
- Card 222 — substrate HA; engine rename should land before
  Stage 2 hub migration to avoid renaming twice.
- `nsc-jwt-migration.md` — JWT migration also touches account
  name; sequence carefully (do this card first or together).
- Card 215 — multi-role task cards; per-role logic in agents
  shouldn't assume specific role names.
