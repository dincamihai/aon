---
column: Backlog
priority: low
created: 2026-04-29
source: joana audit (F4) on 4d5911b..62dc26d
---

# `cmd_connect`: `reply_subj` defined but never used

Commit `32daffe` (`feat(aon): add cmd_connect for waiting-room joiner flow`).

`bin/aon:2760` — `reply_subj='team.${team}.waiting-room.${box_id}.reply'` is defined but never passed to `nats req` or subscribed. `nats req` uses its own `_INBOX.*` instead.

## Fix

Either:
- Remove the dead variable, OR
- Use it to fix `admit-list-loses-reply-to-envelope` (F3): embed in JSON payload so admin can reconstruct reply target.

The second option is preferred — fixes the higher-priority bug at the same time.

## Acceptance

1. No unused `reply_subj` in `cmd_connect`.
2. If reused for F3 fix: variable is included in the published payload.
