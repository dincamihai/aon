---
column: Backlog
created: 2026-04-26
order: 132
---

# A2A pull-vs-push hybrid

Slice 1 introduced directed dispatch (Maya picks worker by skill).
This breaks MODEL.md §"Generalists self-route" — Raj wants to scan
the board and grab interesting work, not wait for Maya to assign.

Slice 2 restores the property by adding a `dispatch_mode` field to
`a2a_send_task`. Push mode (slice 1 default) sends directed via A2A.
Pull mode publishes to existing `board.tasks.<domain>.pending`
workqueue — any subscribed worker can claim. Both flows leave
identical AUDIT trails (per investigation card §"Tests as cutover
oracle").

## Deliverables

### 1. `dispatch_mode` field

`a2a_send_task(skill, payload, dispatch_mode="push", ...)`:
- `"push"` (default) — slice 1 behavior; pick by skill match, send
  on `a2a.<target>.tasks.send`.
- `"pull"` — translate skill → domain (skill IS domain in current
  taxonomy; one-to-one), publish to `board.tasks.<domain>.pending`
  with the A2A payload wrapped. Workers claim via existing
  `claim_task` tool.

### 2. Skill ↔ domain mapping

Add `team_alpha_mcp/a2a/skill_map.py` — single function
`skill_to_domain(skill: str) -> str | None`. For slice 2, identity
mapping (`python` → `python`). Future: richer skill taxonomy like
`python.django` → domain `python`.

### 3. AUDIT bridge for pull mode

In pull mode, the dispatcher also publishes a synthetic
`a2a.unassigned.tasks.<task_id>.status = submitted` event so AUDIT
contains the task even before any worker claims. When a worker
claims via `claim_task`, the bridge promotes the substrate event to
A2A `.status = working` on `a2a.<claimer>.tasks.<task_id>.status`
(this is the slice-2 cutover seam — not full dual-write yet).

### 4. Tool default

Maya's prompt: "use `dispatch_mode='pull'` when ≥2 candidates exist
at the same primary tier and either could do the work; use
`'push'` when continuity matters or only one candidate exists".

### 5. Smoke 20

`scripts/smoke/20-a2a-pull-mode.sh`:
- maya dispatches skill=python with `dispatch_mode='pull'`
- assert msg appears on `board.tasks.python.pending`
- assert no `a2a.<role>.tasks.send` publish happened
- raj claims via existing `claim_task`
- assert AUDIT shows the bridge promotion event

## Acceptance

- [ ] `a2a_send_task(dispatch_mode="pull")` posts to
      `board.tasks.<domain>.pending`.
- [ ] `a2a_send_task(dispatch_mode="push")` unchanged from slice 1.
- [ ] Smoke 20 green; existing smokes (incl. 17) still green.
- [ ] MODEL.md §"A2A layer" updated with hybrid table.

## Refs

- `team-alpha-a2a-impl-slice2.md` — umbrella.
- MODEL.md §"Generalists self-route" — invariant restored here.
