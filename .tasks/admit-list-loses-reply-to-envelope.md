---
column: Done
priority: high
created: 2026-04-29
source: joana audit (F3) on 4d5911b..62dc26d
---

# `aon admit list` drains waiting-room with `--raw`, losing reply-to — `approve` cannot close loop

Commit `3bb3312` (`feat(aon): add cmd_admit_list for waiting-room admin`).

`bin/aon:2623` — admin uses `nats sub --raw` which strips NATS headers including reply-to subject.

Joiner uses `nats req` (reply-to = `_INBOX.*`). Admin drains JSON payloads but has no way to reply. The `approve` subcommand (not yet implemented) cannot close the loop. Joiner will time out.

## Design fix

Joiner-side: embed `reply_subj` in the JSON payload so admin can reconstruct the reply target without needing the wire-level reply-to.

`bin/aon:2760` already defines `reply_subj='team.${team}.waiting-room.${box_id}.reply'` but it's dead code (see `dead-code-reply-subj-in-cmd-connect.md`). Wire it into the payload.

Admin-side: drop `--raw`, or read `reply_subj` from payload.

## Acceptance

1. Joiner publishes JSON containing `reply_subj`.
2. Admin reads `reply_subj` from each payload.
3. `approve` subcommand can publish to `reply_subj` and joiner receives the reply within timeout.
4. End-to-end smoke test in `scripts/nsc-smoke/` covers admit → approve round-trip.

## Why high priority

Blocks the entire `approve` half of waiting-room admin. Without it, admit is half-done — joiners enter the queue but can never be admitted.
