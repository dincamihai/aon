---
column: Backlog
created: 2026-04-26
order: 142
---

# Sim 11 — A2A cancel signal

Maya cancels an in-flight task. Worker receives the cancel,
transitions inflight to `canceled`, publishes
`.status=canceled`, removes from inflight KV.

## Deliverables

### 1. Worker cancel subscription

Extend `team_alpha_mcp/a2a/worker.py` accept loop to ALSO subscribe
`a2a.<self>.tasks.*.cancel`. On message:
- look up task_id in inflight KV; if absent → no-op
- call `lifecycle.transition(<current>, "canceled")`
- publish `a2a.<self>.tasks.<task_id>.status` with state=canceled,
  reason from cancel payload
- remove from inflight KV

### 2. Maya tool: `a2a_cancel_task`

`__main__.py` adds:
- `a2a_cancel_task(target_role, task_id, reason="")` — publishes on
  `a2a.<target_role>.tasks.<task_id>.cancel`. Manager-only.
- ACL: maya's `a2a.*.tasks.*.cancel` already in publish allow
  (slice 2 smoke 19 verified).

### 3. Sim scenario 11

`scripts/sim/scenario-11-a2a-cancel.sh`:
1. Maya dispatches skill=terraform → priya accept.
2. Sim sleeps 200ms (priya is "working").
3. Maya calls `a2a_cancel_task("priya", task_id, reason="rescoped")`.
4. Assert priya emits `.status=canceled` within 2s.
5. Assert KV `a2a.priya.inflight` no longer contains task_id.
6. AUDIT shows working → canceled chain.

### 4. Smoke 24

`scripts/smoke/24-a2a-cancel.sh`:
- worker auto-accepts a task
- maya publishes cancel
- worker emits .status=canceled
- inflight cleared
- non-maya cancel attempt denied (already in smoke 19; sanity check)

## Acceptance

- [ ] Worker accept loop handles cancel subscription.
- [ ] `a2a_cancel_task` MCP tool registered, manager-only.
- [ ] Sim 11 green; full cancel chain visible.
- [ ] Smoke 24 green.

## Refs

- `team-alpha-a2a-impl-slice3.md` — umbrella.
- `team-alpha-a2a-worker-accept-loop.md` (slice 2 card 131).
