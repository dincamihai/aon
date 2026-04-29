---
column: Backlog
priority: critical
created: 2026-04-29
source: rona exploratory (Bug 4) on 4d5911b..62dc26d
---

# CRITICAL: waiting-room broken — NATS Core race drops `aon connect` request if admin not pre-subscribed

`bin/aon` (`cmd_connect` + `cmd_admit_list`).

NATS Core has **no persistence**. `aon connect` publishes a `nats req` to `team.<team>.waiting-room`. If the admin isn't already subscribed at that instant, the message is dropped silently. `aon admit list` then returns zero pending requests.

## Repro

1. `aon connect workers` — sends req, waits 300s.
2. Within 1s: `aon admit list workers` — **no pending requests**.
3. Only ordering that works: admin's `admit list` is running *before* the joiner sends `connect`.

## Impact

The waiting-room flow is unusable for any realistic scenario where joiner and admin act independently. This is the architectural root cause; the `--raw` reply-to bug (`admit-list-loses-reply-to-envelope.md`) and the timeout-flag bug (`cmd-connect-nats-req-wait-flag-wrong.md`) are downstream of this — both go away once persistence is added.

## Fix options

**Option A — JetStream subject (preferred):**
- Bootstrap: `ensure_stream WAITING_ROOM "team.*.waiting-room"` (work-queue, retention until admitted, TTL e.g. 30 min).
- Joiner publishes to the stream subject; admin pulls from a durable consumer.
- Reply path: still needs F3 fix (embed `reply_subj` in payload) since reply is non-JS.

**Option B — KV-based:**
- Joiner writes join-request to `$KV.waiting-room.<team>.<box_id>` with TTL.
- Admin watches `$KV.waiting-room.<team>.>` for new keys.
- Approve writes decision back to a child key; joiner watches.
- Pro: KV TTL handles cleanup naturally; admin drain order doesn't matter. Con: rewires more of `cmd_connect`.

**Option C (band-aid, not a real fix):**
- Document "admin must run `admit list` before joiner connects" — fragile, doesn't survive concurrent joiners.

## Acceptance

1. Joiner can run `aon connect` *before* admin runs `admit list`. Admin sees the pending request when they eventually call `admit list`.
2. Multiple concurrent joiners all visible to admin.
3. End-to-end smoke test in `scripts/nsc-smoke/` covers connect-before-admin and connect-after-admin orderings, both pass.
4. Pending requests have a TTL (e.g. 30 min) so abandoned joiners don't accumulate.

## Related

- `admit-list-loses-reply-to-envelope.md` (F3) — reply-to design fix; still needed regardless of A or B.
- `cmd-connect-nats-req-wait-flag-wrong.md` (D3) — currently 5s timeout; once persistence lands, the joiner-side timeout still matters but the race goes away.
- `admit-list-invalid-duration-flag.md` (D1) — fix this so `admit list` actually drains anything once persistence is in.
- `anon-deny-pub-overrides-allow-list.md` (D2) — without this, anon can't publish at all.
