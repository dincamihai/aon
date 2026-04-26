---
column: Done
created: 2026-04-25
order: 60
---

# Claude Code hooks — NATS-aware session-start, presence, role guards

Hooks make each session reactive to the substrate without a permanently-running
Monitor.

## Scope

### `scripts/hooks/_lib.sh` — shared

Identity model:

```
TEAM_ALPHA_ROLE   = maya|raj|lin|sam|diego|priya     # required
TEAM_ALPHA_NATS_URL                                  # required
TEAM_ALPHA_CREDS                                     # path to password file (gitignored)
```

If unset → hook no-ops with WARNING.

Helpers:
- `publish_event <subject> <json-payload>` — publishes via `nats pub` using
  role's creds.
- `publish_to_inbox <peer-role> <suffix> <payload>` → `agents.<peer>.inbox`.
- `publish_to_board <domain> <state> <payload>` → `board.tasks.<domain>.<state>`,
  guarded by static role→subjects map (cheap client-side reject before server).
- `now_iso`, `read_hook_stdin`, `jq` payload builder.

### `scripts/hooks/session-start-catch-up.sh`

- Subscribe (one-shot, `--since <cursor>`, `--count 200`) to:
  - `agents.<role>.inbox` (DMs you missed)
  - role-relevant `board.tasks.<domain>.pending` (work that arrived while idle)
  - `broadcast.>` (incidents, standup)
- Inject summary as `additionalContext` (`hookSpecificOutput.SessionStart.additionalContext`).
- Cursor: `~/.team-alpha/last-seen-<role>` (ISO timestamp, JetStream pull is by
  time, not line number).
- Cap to last 50 entries to bound context cost.

### `scripts/hooks/stop.sh`

When session ends:
- Update KV `state.agent.<role>.load = idle`.
- Publish `session_end` to `agents.<role>.events` (Maya is subscribed to
  `agents.*.events`, gets presence signal).

### `scripts/hooks/user-prompt-submit.sh` (P2, optional)

Inject low-volume context: current load (KV), top unclaimed task in role's
domain. Skip if last injection <60s ago (avoid spam).

### `scripts/hooks/install.sh`

Wires hooks into `.claude/settings.json` (project-level). Idempotent.

## Files

- `scripts/hooks/_lib.sh`
- `scripts/hooks/session-start-catch-up.sh`
- `scripts/hooks/stop.sh`
- `scripts/hooks/user-prompt-submit.sh` (P2)
- `scripts/hooks/install.sh`
- `.claude/settings.json` — committed wiring; per-host `settings.local.json`
  gitignored.

## NOT in scope

- `post-tool-use` hook firing on `.tasks/*.md` edits → wrong layer. `.tasks/`
  here is the dev kanban for *building* this substrate, not the runtime team
  board. Runtime board lives on NATS subjects (`board.tasks.>`), driven by the
  agent's own publish calls (e.g. when claiming a task it publishes
  `board.tasks.<domain>.claimed`), NOT by file edits.
- Audit dual-write to JSONL → AUDIT stream handles persistence server-side.

## Acceptance

- [ ] All hooks no-op cleanly when env unset (`TEAM_ALPHA_ROLE` missing) — warn
      to stderr, exit 0.
- [ ] `session-start-catch-up.sh` produces `additionalContext` with last 50
      events for that role's subscriptions, advances cursor.
- [ ] `stop.sh` writes KV `state.agent.<role>.load=idle` and publishes
      `session_end` exactly once per session.
- [ ] Hook publish failures (NATS down, perms denied) log + exit 0; never block
      tool use.
- [ ] `install.sh` is idempotent — running twice leaves identical state.
- [ ] Permission guard in `_lib.sh` rejects ill-routed publishes locally before
      hitting server (faster feedback for misconfigured prompts).
- [ ] No references to private repos / external paths in any committed file.

## 2026-04-26 follow-up

Card was marked Done in April but role-dir wiring was missing — the
hooks fired only when claude was launched from `~/Repos/ai-over-nats`,
not from `~/team-alpha/<role>/`. T1 live retest surfaced the gap.

Fixed today:
- `_lib.sh` falls back to `${PWD##*/}` for role + `~/.team-alpha/<role>.password`
  for creds + `nats://localhost:4222` for URL when env unset. Self-identifying
  role dirs.
- `install.sh role-dirs` subcommand stamps `.claude/settings.json` into
  each `~/team-alpha/<role>/`. Idempotent.
- Verified standalone for priya: catch-up emits `additionalContext`
  JSON, onboard primes Monitor instructions, stop sets
  `agent.priya.load.capacity=idle` in KV.

Card 210 extends from here w/ Monitor exact-params, idle drill,
recap_request round-trip.
