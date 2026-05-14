---
column: Backlog
created: 2026-05-14
order: 170
---

# A2A smoke 20 — pull-mode roundtrip

Smoke 17 covers push-mode dispatch end-to-end. The `a2a_send_task()`
tool supports `dispatch_mode='pull'` (routes via `board.tasks.<domain>.pending`)
but no smoke verifies the full pull-mode lifecycle, nor the AUDIT
bridge events that should accompany it.

## Deliverables

### `scripts/smoke/20-a2a-pull-mode.sh`

Full pull-mode roundtrip:

1. **Dispatch** — call `a2a_send_task(skill="python", payload=...,
   dispatch_mode="pull")` as Maya.
   Assert: `board.tasks.python.pending` receives message with
   correct task_id + payload.
   Assert: synthetic `a2a.unassigned.tasks.<id>.status=submitted`
   published to `A2A_TASKS` stream (requires dual-write bridge
   fix from `pull-push-hybrid` card 132).

2. **Claim** — worker calls `claim_task(slug)` on the board task.
   Assert: `board.tasks.python.pending` transitions to `claimed`.
   Assert: `a2a.<worker>.tasks.<id>.status=working` mirrored via
   bridge (requires `dual-write-cutover` card 143).

3. **Complete** — worker calls `complete_task(slug)`.
   Assert: board task moves to `done`.
   Assert: `a2a.<worker>.tasks.<id>.status=completed` mirrored.

4. **AUDIT trail** — query AUDIT stream for task_id; assert
   submitted → working → completed in order with correct timestamps.

5. **ACL** — non-Maya role attempting pull dispatch denied
   (pub to `board.tasks.*.pending` gated by ACL).

### Dependency note

Steps 2–3 depend on `pull-push-hybrid` (132) + `dual-write-cutover`
(143) being complete. Smoke 20 can be merged with a
`# TODO: steps 2-3 require cards 132+143` guard until then.

## Acceptance

- [ ] Step 1 (dispatch + submitted mirror) green independently.
- [ ] Steps 2–3 green after cards 132 + 143 ship.
- [ ] Smoke 20 included in `scripts/smoke/run-all.sh`.
- [ ] No regression in smokes 17–19.

## Refs

- `team-alpha-a2a-smokes-18-19.md` — preceding smokes.
- `team-alpha-a2a-pull-push-hybrid.md` (132) — AUDIT bridge for pull.
- `team-alpha-a2a-dual-write-cutover.md` (143) — substrate mirror.
- `mcp-server/src/aon_mcp/__main__.py:754` — pull-mode tool impl.
