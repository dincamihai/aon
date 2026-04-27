---
column: Backlog
created: 2026-04-27
order: 246
priority: low
parent: team-alpha-meta-aon-init-flow
---

# Card 246 — `scripts/bootstrap.sh` final message reflects roster

After `aon bootstrap` against a 2-role poc roster the script
still prints:

```
✓ team-alpha substrate bootstrapped.
  streams: TASKS LEARNING RESULTS EVENTS AUDIT
  kv:      team-state
  seeded:  roster, agent.<role>.{skills,load} for 6 roles
```

The hardcoded `team-alpha`, `team-state`, and `6 roles` are
stale once `AON_ROSTER` / `AON_KV_BUCKET` get parameterized
(Card 238 already passes them).

## Fix

Replace the hardcoded values with shell variables already in
scope:

```
✓ ${AON_TEAM_NAME:-team} substrate bootstrapped.
  streams: …
  kv:      $AON_KV_BUCKET
  seeded:  roster, agent.<role>.load for $(echo $AON_ROSTER | wc -w | tr -d ' ') roles
```

Plus add `$AON_TEAM_NAME` to the env block in `cmd_bootstrap`
(bin/aon).

## Acceptance

- 2-role poc → final line says `2 roles`, `kv: poc-state`.
- Default 6-role team-alpha → unchanged output.

## Why

Cosmetic. Removes a "is the bootstrap actually doing the right
thing?" moment for the operator.
