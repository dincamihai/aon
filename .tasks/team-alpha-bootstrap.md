---
column: Done
created: 2026-04-25
order: 30
---

# Bootstrap script — JetStream streams, KV bucket, smoke test

Idempotent script that brings a fresh NATS server up to the state MODEL.md
§"What you'd actually build" describes.

## Scope

`scripts/bootstrap.sh` (bash). Run after `docker compose up -d nats`. Uses the
`nats` CLI under an admin user (add a `sysadmin` user to nats-server.conf with
permissions `>` — see `team-alpha-nats-config.md`).

Steps, all idempotent (use `nats stream add --config` / `nats kv add` w/
existence checks):

1. Wait for NATS reachable (`nats server check connection`, retry loop, timeout 30s).
2. Create JetStream streams:
   - `TASKS` — subjects `board.tasks.>`, retention `workqueue`, storage `file`,
     max-age 30d.
   - `LEARNING` — subjects `board.learning.>`, retention `workqueue`, storage
     `file`, max-age 30d.
   - `RESULTS` — subjects `board.results.>`, retention `limits`, storage `file`,
     max-msgs-per-subject 100, max-age 90d.
   - `AUDIT` — subjects `>` (mirror everything except `audit.>` to avoid loop),
     retention `limits`, storage `file`, max-age 365d.
3. Create KV bucket:
   - `team-state` — history 5, ttl unset, storage `file`. Hosts
     `state.project.<id>`, `state.agent.<id>.load`, `state.agent.<id>.skills`,
     `state.team.alpha.roster`.
4. Seed initial KV values:
   - `state.team.alpha.roster` = `["maya","raj","lin","sam","diego","priya"]`.
   - `state.agent.<id>.skills` for each user, primary/growing per MODEL.md.
5. Smoke test: publish + sub on `broadcast.standup`, assert round-trip.

## Files

- `scripts/bootstrap.sh` — main entry.
- `scripts/lib/nats-helpers.sh` — small helpers (`have_stream`, `have_kv`).
- `scripts/seed-skills.json` — seed payload for KV step 4.

## Inputs

- Env: `NATS_URL` (default `nats://localhost:4222`), `NATS_ADMIN_USER`
  (default `sysadmin`), `NATS_ADMIN_PASSWORD` (required).

## Acceptance

- [ ] Running twice in a row exits 0 both times (idempotent).
- [ ] `nats stream ls` shows TASKS, LEARNING, RESULTS, AUDIT.
- [ ] `nats kv ls` shows `team-state` w/ seeded keys.
- [ ] AUDIT does not loop on itself (excludes `audit.>` subject).
- [ ] Smoke test publishes 1 msg, receives it within 5s.
- [ ] Script fails fast with clear error if `NATS_ADMIN_PASSWORD` unset.
