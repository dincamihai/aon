---
column: Done
created: 2026-04-26
order: 207
---

# Defect 207 — Worker has no surface to see auto-accepted tasks

**Fixed 2026-04-26.** Added MCP tool `a2a_inbox()` in
`mcp-server/src/team_alpha_mcp/__main__.py:420` backed by new helper
`list_inflight()` in `mcp-server/src/team_alpha_mcp/a2a/worker.py`.
`recent_events` now warns when called on `*.tasks.send` subject
(non-JS-stored by design) and redirects to `a2a_inbox`. Priya role
prompt updated with "A2A workflow" section telling her to poll
`a2a_inbox()`, not `recent_events`. Smokes green. Subagent T1 used
`list_inflight` (the lib equivalent) and saw inbox tasks within 2s.
Real-Claude retest pending session restart.

Observed in card 151 lightweight live test, T1.

## Symptom

Maya dispatched `a2a_send_task(skill="terraform", ...)`. Priya's
accept loop auto-accepted (KV `a2a.priya.inflight` got
`t-40c5158171bc` with state=working at 13:46:03). But priya the
LLM had no tool surface to discover this. She fell back to polling
`recent_events('a2a.priya.tasks.send', since='5m')` which returns
empty because `tasks.send` is intentionally NOT JS-stored
(`bootstrap.sh:42-46`).

Priya entered an infinite poll/sleep loop ("Empty. Next 10min.")
while a task sat in her KV queue.

## Root cause

No `a2a_inbox` MCP tool. Accept loop writes to KV but no read
surface exposed to LLM. Worker prompt also doesn't say "your
accept loop runs in the background; check inflight via
`a2a_inbox`."

## Fix

1. Add MCP tool `a2a_inbox()` → reads
   KV `a2a.<self>.inflight`, returns list of `{task_id, state,
   skill, from, since, parent_task_id, project_id}`.
2. Worker system prompt: "Tasks dispatched to you are
   auto-accepted by the MCP lifespan loop and recorded in
   `a2a_inbox()`. Poll that, not `tasks.send`."
3. `recent_events` docstring: warn that `tasks.send` is
   non-JetStream and will always return empty; redirect to
   `a2a_inbox()`.

## Acceptance

- [ ] `a2a_inbox()` tool returns inflight tasks for current role.
- [ ] Cold priya session, after maya dispatches, picks task up
      within first turn via `a2a_inbox`, no 10-min poll loop.
- [ ] `recent_events` rejects/warns on `tasks.send` subject.

## Refs

- `team-alpha-a2a-live-test-lightweight.md` — origin (T1).
- `mcp-server/src/team_alpha_mcp/a2a/worker.py:140` —
  `start_accept_loop`.
- Recap line 31-32 — `tasks.send` non-stored design rationale.
