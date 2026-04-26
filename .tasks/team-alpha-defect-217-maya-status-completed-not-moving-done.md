---
column: Backlog
created: 2026-04-26
order: 217
---

# Defect 217 — Maya doesn't reliably move card to Done on `.status=completed`

> **Status (2026-04-26):** Option B (stronger maya prompt rule)
> landed in `scripts/agent-prompts/maya.md` — new "On worker
> completion — DETERMINISTIC" section. Helps if maya is ever
> seated in a simulation. **Tomorrow's live session does not seat
> maya** — coordination is hands-on by the operator (move cards
> to Done manually via `update_task`). Defect dies fully when
> Card 220 (delegate + SDK) lands and structured SDK return
> values drive card moves automatically.

## Symptom

Worker emits `a2a_update_status(task_id, "completed", artifact=...)`.
Maya's Monitor delivers the event. Card stays in `in-progress/`
column. Operator must manually move the card or re-prompt maya.

Observed in T1, T3 of 2026-04-26 live runs (P1+P2 of card 213).

## Root cause (suspected)

Two candidate paths:

1. **LLM categorization miss** — Monitor delivers raw NATS event;
   maya's prompt asks her to recognize `.status=completed` and
   call `mcp__team-alpha-board__move_task(slug, "done")`. She
   sometimes interprets the event as informational and replies in
   chat instead of issuing the tool call. No deterministic
   trigger.
2. **slug ↔ task_id mapping lost** — completion event carries
   `task_id` (a2a id `t-…`); board card uses `slug`
   (`tb-…-vpc-peering`). Maya needs to remember the binding from
   dispatch time. If transcript paged out, she can't map.

## Fix path

### A — Deterministic move via hook (preferred)

Add a hook in maya's role pipeline: a "completion mover" that
subscribes to `a2a.*.tasks.*.status` filtered to
`state=completed`, looks up the slug from
`a2a.<role>.inflight` KV (which maya already writes on dispatch
with `{task_id, slug, target}`), and calls
`mcp__team-alpha-board__move_task(slug, "done", {result_summary,
artifact_ref})` directly. No LLM in the loop.

Implementation: a small daemon or a maya-side post-event hook in
`mcp-server/src/team_alpha_mcp/board_wrapper.py`.

### B — Stronger prompt scaffolding (cheap, partial)

In `scripts/agent-prompts/maya.md` add an explicit decision rule:

```
## On worker completion

When Monitor delivers `a2a.<role>.tasks.<task_id>.status` with
`state=completed`:
1. Look up the slug bound to `task_id` in your dispatch log
   (you wrote it when calling `a2a_send_task`).
2. Call `mcp__team-alpha-board__move_task(slug, "done")`.
3. Append `## Result` section to the card via
   `mcp__team-alpha-board__update_task` with the artifact.
4. Do NOT just reply in chat — the card move is the contract.
```

### C — Slug in task_id (schema change)

Make `task_id == slug` so the binding is the identity. Removes
the mapping problem. Larger change, affects A2A IDs everywhere.

## Recommendation

Ship A. It removes the LLM judgment from a deterministic
state transition. Keep B as defense-in-depth in the prompt. C is
out of scope.

## Files

- `mcp-server/src/team_alpha_mcp/board_wrapper.py` — completion
  subscriber + `move_task` call.
- `scripts/agent-prompts/maya.md` — completion-discipline section.
- `mcp-server/src/team_alpha_mcp/__main__.py` — ensure dispatch
  writes `{task_id, slug}` into `a2a.<role>.inflight` KV (verify
  current behavior, extend if missing).

## Acceptance

- [ ] Worker emits `a2a_update_status(...,"completed",...)`. Card
      moves to `done/` within 2s without operator action.
- [ ] `## Result` section appended with artifact summary.
- [ ] Re-emission of same `completed` event is idempotent (no
      double-move, no double-append).
- [ ] If KV inflight entry missing (dispatch not via maya), hook
      logs warning and no-ops — never crashes.

## Refs

- Card 213 P1+P2 — runtime board flow this defect blocks.
- Card 210 — Monitor pattern that delivers status events.
- T1 / T3 retest 2026-04-26.
- `mcp-server/src/team_alpha_mcp/a2a/worker.py:_handle_status_update`
  — completion emit site.
