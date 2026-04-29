---
column: In Progress
created: 2026-04-29
priority: high
parent: waiting-room-admit
phase: 1
step: 5
assigned_to: tim
---

# waiting-room-admit step 5 — `aon admit list`

`cmd_admit_list` in bin/aon. Subscribe `team.<team>.waiting-room`, drain pending, print box_id + hostname + user + requested_role + fingerprint + age. Cross-check against `admits.log` for dup detection display.

## Scope

Add `aon admit list` subcommand per parent card phase 1 step 5 spec.

## Acceptance

1. `aon admit list` subscribes to `team.<team>.waiting-room`, drains pending.
2. Output columns: box_id, hostname, user, requested_role, fingerprint, age.
3. Cross-checks against `~/.aon/teams/<team>/admits.log` for duplicates.
4. No pending requests → clean "no requests" message.
5. `aon admit list --help` works.
6. No interactive prompts.

## Out of scope

- Approve/reject logic (steps 6-7).
- TUI (Phase 2).
