---
column: Backlog
created: 2026-04-26
order: 136
---

# A2A — deprecate KV `agent.<role>.skills`

Slice 1 made `agents/<role>.json` (in git) the source of truth for
skills + tier (drift resolution #1, slice 1 §c). Slice 2 finishes
the migration: stop writing the legacy KV key, migrate any reader.

## Current state

`scripts/bootstrap.sh` seeds KV `agent.<role>.skills` from
`scripts/seed-skills.json`. Only writers today. Readers:
- `bin/team-alpha-status` — TUI dashboard.
- agent prompts (text files in `scripts/agent-prompts/`) — informational.
- maybe `coordinator-watcher.sh` (verify; likely none).

## Deliverables

### 1. Stop seeding

Remove the `kv_put team-state agent.${role}.skills "$skills"` loop
from `scripts/bootstrap.sh`. Drop `scripts/seed-skills.json` (covered
by `agents/*.json` now). Bootstrap still seeds `agent.<role>.load`.

### 2. Migrate readers

- `bin/team-alpha-status` — change `read_kv agent.<role>.skills` to
  reading `agents/<role>.json` from disk; render same TUI.
- Agent prompts — replace any "your skills are" reference with a
  pointer to `agents/<role>.json` for the canonical list.

### 3. Tombstone existing keys

One-shot `scripts/migrate-2026-04-skills-kv.sh`: for each role,
`nats kv del team-state agent.<role>.skills`. Idempotent. Run once
post-deploy.

### 4. CI / docs

- `scripts/gen-agent-cards.py` already authoritative; nothing to add
  here.
- MODEL.md note (already added in slice 1) updated with "KV skills
  deprecated, see `agents/*.json`".

### 5. Smoke 22

`scripts/smoke/22-skills-source-of-truth.sh`:
- assert `agents/<role>.json` parseable for each role.
- assert KV `agent.<role>.skills` returns nothing (post-migration).
- assert `bin/team-alpha-status` shows skills (no crash from missing KV).

## Acceptance

- [ ] Bootstrap no longer writes `agent.<role>.skills`.
- [ ] `bin/team-alpha-status` reads from git file.
- [ ] Migration script removes existing KV keys idempotently.
- [ ] Smoke 22 green; all existing smokes still green.
- [ ] `scripts/seed-skills.json` removed.

## Refs

- `team-alpha-a2a-impl-slice2.md` — umbrella.
- `team-alpha-a2a-impl-slice1.md` §"Decisions deferred" #2.
