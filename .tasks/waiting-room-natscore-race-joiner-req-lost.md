---
column: In Progress
priority: critical
created: 2026-04-29
source: rona exploratory (Bug 4) on 4d5911b..62dc26d
decision: 2026-04-29 — KV both ways, per-team bucket (mid + sun)
implementation-plan: ~/.claude/plans/let-s-discuss-the-critical-abstract-pizza.md
subtasks:
  - waiting-room-kv-bootstrap-and-anon-acl.md (tim)
  - waiting-room-cmd-connect-kv-rewrite.md (tim)
  - waiting-room-cmd-admit-list-and-approve-reject.md (tim)
  - waiting-room-kv-e2e-test.md (rona)
  - waiting-room-kv-code-review.md (joana)
supersedes:
  - admit-list-loses-reply-to-envelope.md (F3)
  - dead-code-reply-subj-in-cmd-connect.md (F4)
  - cmd-connect-nats-req-wait-flag-wrong.md (D3)
---

# CRITICAL: waiting-room broken — NATS Core race drops `aon connect` request if admin not pre-subscribed

`bin/aon` (`cmd_connect` + `cmd_admit_list`).

NATS Core has **no persistence**. `aon connect` publishes a `nats req` to `team.<team>.waiting-room`. If the admin isn't already subscribed at that instant, the message is dropped silently. `aon admit list` then returns zero pending requests.

## Repro

1. `aon connect workers` — sends req, waits 300s.
2. Within 1s: `aon admit list workers` — **no pending requests**.
3. Only ordering that works: admin's `admit list` is running *before* the joiner sends `connect`.

## Decision (2026-04-29)

**KV both ways, per-team dedicated bucket.**

- New per-team bucket `${team}-waiting-room` (TTL 30m, history 1).
- Joiner writes `request.<box_id>` key, watches `reply.<box_id>`.
- Admin lists keys, reads requests, writes `reply.<box_id>` keys.
- Anon ACL grants only `$KV.${team}-waiting-room.>` (zero blast radius into `workers-state`).
- Removes the broken NATS Core pub/sub from both joiner + admin code paths.

Rejected: pure JetStream (Option A) requires durable consumer plumbing for reply path; mixing JS + KV adds complexity. KV is symmetric, native list/get/watch, TTL native.

Full plan: `~/.claude/plans/let-s-discuss-the-critical-abstract-pizza.md`.

## Acceptance

1. Joiner can run `aon connect` *before* admin runs `admit list`. Admin sees the pending request when they eventually call `admit list`.
2. Multiple concurrent joiners all visible to admin.
3. End-to-end smoke test in `scripts/nsc-smoke/` covers connect-before-admin and connect-after-admin orderings, both pass.
4. Pending requests have a TTL (30 min) so abandoned joiners don't accumulate.
5. `aon admit approve <box_id>` + `aon admit reject <box_id>` close the loop end-to-end.

## Subtasks

| ID | File | Owner | Blocks |
|----|------|-------|--------|
| 1 | `waiting-room-kv-bootstrap-and-anon-acl.md` | tim | 2, 3 |
| 2 | `waiting-room-cmd-connect-kv-rewrite.md` | tim | 4 |
| 3 | `waiting-room-cmd-admit-list-and-approve-reject.md` | tim | 4 |
| 4 | `waiting-room-kv-e2e-test.md` | rona | (none) |
| 5 | `waiting-room-kv-code-review.md` | joana | merge |

## Supersedes (close after merge)

- F3 `admit-list-loses-reply-to-envelope.md`
- F4 `dead-code-reply-subj-in-cmd-connect.md`
- D3 `cmd-connect-nats-req-wait-flag-wrong.md`

D1 (`admit-list-invalid-duration-flag.md`) already shipped in `sun/fix-trivials-2026-04-29` — irrelevant once `nats sub --raw` is gone, but trivial fix stays as defense-in-depth on its own merits.
