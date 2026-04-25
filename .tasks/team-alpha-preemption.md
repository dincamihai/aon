---
column: Backlog
created: 2026-04-25
order: 85
---

# Preemption — priority change while task in progress

Scenario: worker (or its human) is mid-execution on a low-priority task. A
high-priority change arrives. Worker should pause low-prio, switch to
high-prio, return to low-prio when high-prio completes.

## Premise

- Coordinator (Maya) re-publishes a task with elevated priority (or posts a
  new high-prio task with `preempts: <slug>`).
- Worker is responsible for honoring preemption — substrate signals it,
  prompt enforces the behavior.
- Low-prio task is **parked**, not abandoned. State preserved in KV +
  worker's branch. Returns to it after high-prio done.

## Scope

### Conventions

- **Preempt signal**: Maya publishes
  `board.tasks.<domain>.pending` w/ payload field `preempts:<slug>` (or
  `priority:high` re-publish of existing slug with `supersedes` flag). The
  worker's session listens on its own task domain pending; receiving
  preempt signal triggers parking.
- **Park**: worker writes
  `state.agent.<role>.parked = [{"slug": "...", "branch": "...", "since":
  "..."}]` to KV team-state, emits
  `board.tasks.<domain>.parked` event w/ slug + reason.
- **Switch**: worker claims the high-prio task as usual.
- **Resume**: when high-prio task hits `done` and no other higher prio
  pending, worker reads its `parked` list, pops oldest, emits
  `board.tasks.<domain>.resumed`, continues.
- **Multi-park**: if a parked task gets preempted again (cascade), the
  parked list is a stack — LIFO resume.

### Smoke scripts

- `11-preempt-park-resume.sh`:
  1. Maya posts low-prio terraform task.
  2. Priya claims, emits `claimed` + `progress`.
  3. Maya posts high-prio terraform task w/ `preempts:<low-slug>`.
  4. Assert: Priya emits `parked` event w/ low-slug, then `claimed` for
     high-slug, then `progress` on high-slug.
  5. Synthesize Priya emitting `done` for high.
  6. Assert: Priya emits `resumed` for low-slug (or alert if she didn't).
- `12-preempt-cascade.sh`: low → med → high → med-done resume → low-done
  resume. Verify stack order.

### Detection mechanism (HITL fallback)

- If a worker has a `parked` entry older than `PARKED_TTL_HOURS`, the
  coordinator-watcher emits `state.alert.parked_stale` on `state.alert.>`,
  Maya gets paged. She decides: nudge worker, reassign, or close.

## Files (when implemented)

- `scripts/smoke/11-preempt-park-resume.sh`
- `scripts/smoke/12-preempt-cascade.sh`
- updates to coordinator-watcher (from
  `team-alpha-github-cards-workflow.md`) to add parked-stale detection
- agent-prompt updates (card 50) for preempt/park/resume protocol

## Acceptance

- [ ] 11 + 12 pass.
- [ ] Parked-stale alert fires after synthetic stale entry.
- [ ] Resume order is LIFO across cascade.
- [ ] Worker's role prompt explicitly documents the preempt protocol — what
      to park, what to keep (open files? terminal state?), what marker to
      commit.

## Open questions

- Park granularity: per-task or per-session? Currently per-task —
  multi-tasking workers can park N items independently.
- What about uncommitted work-in-progress on parked branch? Convention:
  worker commits as `wip(<slug>): <preempt-marker>` before switching, so
  branch is restorable.
