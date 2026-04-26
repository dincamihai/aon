---
column: Backlog
created: 2026-04-26
order: 134
---

# A2A sim scenario 09 — dispatch by skill match

End-to-end simulation. Validates the slice-2 wiring under the same
sim harness as scenarios 01–08.

## Scope

`scripts/sim/scenario-09-a2a-dispatch.sh`:

1. Ensure stack + bootstrap.
2. Start MCP servers for maya + priya (others optional).
3. Maya: `a2a_send_task(skill="terraform", payload={summary:"VPC
   peering", ...})`.
4. Dispatcher resolves candidates via `agents/*.json` → [priya, raj].
5. Continuity bias: no parent_task_id → load-aware fallback.
6. Maya sends `tasks/send` on `a2a.priya.tasks.send` (lower load).
7. Priya's accept loop ack-replies + publishes
   `a2a.priya.tasks.<id>.status = working`.
8. Priya runs (simulated) work, calls `a2a_update_status(state=
   completed, artifact={pr_url:...})`.
9. Maya verifies via `recent_events('a2a.priya.tasks.<id>.status')`
   the chain submitted → working → completed.

## Assertions

- AUDIT contains all three lifecycle events with matching task_id.
- `a2a.priya.inflight` KV cleared after `completed`.
- KV `project.<pid>.last_worker = {role:"priya"}` if `project_id`
  was set.
- Maya's `a2a_send_task` returns `{task_id, target_role:"priya",
  ack:{ok:true}}`.

## Variants

- 09a — skill="terraform" with `parent_task_id` set, where prior
  task was completed by raj → continuity bias picks raj over priya
  even if raj has higher load.
- 09b — skill not in any card (e.g. "rust") → dispatcher returns
  error, no NATS publish.

## Acceptance

- [ ] Three scenarios (09, 09a, 09b) green.
- [ ] Added to `scripts/sim/run-all.sh`.
- [ ] No regression in existing sims 01–08.

## Refs

- `team-alpha-a2a-impl-slice2.md` — umbrella.
- `team-alpha-a2a-worker-accept-loop.md` — accept loop is its prereq.
