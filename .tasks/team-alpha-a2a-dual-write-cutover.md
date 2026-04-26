---
column: Backlog
created: 2026-04-26
order: 143
---

# A2A dual-write cutover

Existing tools (claim_task, block_task, complete_task, park_task,
resume_task) already publish on `board.tasks.<d>.<state>`. Add a
parallel A2A status publish so AUDIT (and any A2A consumer) sees
the same lifecycle through the canonical vocabulary.

After this slice, the canonical agent-facing surface is A2A.
Substrate `board.>` events remain for backward compatibility but
can be retired in a post-MVP slice.

## Deliverables

### 1. Helper: `team_alpha_mcp/a2a/bridge.py`

- `derive_task_id(slug: str) -> str` — id stable across the lifetime
  of one slug. Default: `f"a2a:{slug}"` (deterministic, no KV state
  needed).
- `mirror_substrate_to_a2a(client, substrate_state, slug, **extra)`
  — uses `lifecycle.map_substrate(...)` to compute (state, reason),
  publishes `a2a.<self>.tasks.<task_id>.status` with the mapped
  state, and writes/clears KV `a2a.<self>.inflight`.

### 2. Wire into existing tools

`__main__.py`:
- After `claim_task` publishes `board.tasks.<d>.claimed`, call
  `mirror_substrate_to_a2a(..., "claimed", slug, ...)`.
- After `block_task` publishes `.blocked`, mirror "blocked".
- After `complete_task` publishes `.done`, mirror "done"
  (terminal — clears inflight).
- After `park_task` publishes `.parked` event, mirror "parked"
  (lifecycle.map_substrate folds to input-required reason="preempted").
- After `resume_task` publishes `.resumed`, mirror "resumed".

### 3. Pull-mode bridge (slice 2 card 132 hook)

When a task arrived via pull mode (`dispatch_mode: "pull"` in the
`board.tasks.<d>.pending` payload), `claim_task` mirrors using the
payload's `task_id` instead of `derive_task_id(slug)`. Caller does
not need to know.

### 4. Smoke 25

`scripts/smoke/25-a2a-dual-write.sh`:
- worker calls existing `claim_task` via subprocess + TeamAlphaClient
- assert `board.tasks.<d>.claimed` published (existing behavior)
- assert `a2a.<role>.tasks.<task_id>.status` with state=working
  ALSO published
- repeat for done → completed, blocked → input-required,
  parked → input-required reason=preempted

### 5. Sim scenario 12 (replay parity)

`scripts/sim/scenario-12-dual-write-parity.sh`:
- run scenario-01 unchanged (Maya posts terraform task; Priya
  claims + ships)
- assert AUDIT now contains BOTH chains:
  - `board.tasks.terraform.{pending,claimed,done}` (4 events)
  - `a2a.priya.tasks.<id>.status` with states {working, completed}
- both chains share the same task_id (via derive_task_id mapping)

## Acceptance

- [ ] All five existing lifecycle tools dual-publish.
- [ ] Smoke 25 green; sim 12 green.
- [ ] No regression in slice 1+2 (smokes + sim 09).
- [ ] MODEL.md §"A2A layer" updated with dual-write note.

## Refs

- `team-alpha-a2a-impl-slice3.md` — umbrella.
- `team-alpha-a2a-investigation.md` §"Tests as cutover oracle" —
  this slice realises the dual-write step described there.
