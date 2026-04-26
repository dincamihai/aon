---
column: Backlog
created: 2026-04-26
order: 133
---

# A2A watcher integration

Coordinator-watcher (`scripts/coordinator-watcher.sh`) detects
substrate invariants (duplicate_claim, stale_claim, parked_stale,
no_human relay). Slice 2 extends it to A2A subjects.

## Deliverables

### 1. New detections

- `a2a_stale_working` — task in `working` state >$A2A_STALE_SEC
  (default 600) with no further status update. Emit
  `state.alert.a2a_stale {task_id, role, age_sec}`.
- `a2a_duplicate_dispatch` — same `task_id` appears on two distinct
  worker subtrees (`a2a.<roleA>.tasks.<id>.status` AND
  `a2a.<roleB>.tasks.<id>.status`). Emit
  `state.alert.a2a_duplicate {task_id, roles:[...]}`.
- `a2a_orphan_inflight` — KV `a2a.<role>.inflight` has entries with
  no recent status update >$A2A_INFLIGHT_TTL (default 1800). Slice 2
  reuses worker-accept-loop's KV from card 131.

### 2. Recent-msgs reuse

The existing `recent_msgs` helper (slice-1.5 fix bounded it to
WATCHER_LOOKBACK) handles `a2a.*.tasks.*.status` cleanly — already
present in AUDIT via A2A_TASKS source.

### 3. Alert plumbing

Extend `tick()` in coordinator-watcher.sh with three new sections;
follow existing emit_alert pattern. No new env beyond
`A2A_STALE_SEC` + `A2A_INFLIGHT_TTL`.

### 4. Smoke 21

`scripts/smoke/21-a2a-watcher.sh`:
- inject A2A status `working` with backdated ts
- run watcher tick; assert `a2a_stale` alert
- inject duplicate-status events under two roles for same task_id
- assert `a2a_duplicate` alert
- inject KV inflight entry with stale `since`
- assert `a2a_orphan_inflight` alert

## Acceptance

- [ ] Three new detections wired into `tick()`.
- [ ] Smoke 21 green; existing 1–20 still green.
- [ ] No tick-time regression (lookback bound holds).

## Refs

- `team-alpha-a2a-impl-slice2.md` — umbrella.
- `team-alpha-a2a-worker-accept-loop.md` — KV `a2a.<role>.inflight`.
- card 85 (preemption) — watcher ergonomics this builds on.
