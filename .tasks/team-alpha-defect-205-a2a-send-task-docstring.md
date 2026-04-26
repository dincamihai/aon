---
column: Done
created: 2026-04-26
order: 205
---

# Defect 205 — `a2a_send_task` docstring confuses dispatch with execution

**Fixed 2026-04-26 in same session.** Docstring rewritten in
`mcp-server/src/team_alpha_mcp/__main__.py:443`. Added explicit
"This tool ONLY queues" lead, "DEFAULT INVOCATION: minimal payload"
guidance, and "When to pick this tool" cues. Maya role prompt
(`scripts/agent-prompts/maya.md`) now has "A2A dispatch" section
covering the same. Smokes 17-25 green. Subagent T1 sim picked
`a2a_send_task` correctly with one-line summary. Real-Claude retest
queued for next session restart.

Observed in card 151 lightweight live test, T1.

## Symptom

Maya refused dispatch with: "Action modify shared infra (terraform /
VPC peering staging). Need explicit auth." Then asked operator for
CIDRs, peer VPC ID, region, accounts before sending.

The tool only enqueues a task for the receiving agent; the dispatcher
never touches infra. Maya's safety reasoning fired on the wrong
verb — she read `send_task(skill=terraform, ...)` as "I am running
terraform."

## Root cause

Tool docstring + name imply action. No clear separation between
"queue work for peer" and "execute work."

## Fix

1. Rewrite `a2a_send_task` docstring. Lead with: "Enqueues a task
   for another agent to execute. This tool does NOT perform the work
   itself — the receiving agent does. Safe to call without
   destructive-action auth."
2. Consider rename → `a2a_delegate_task` (clearer verb). Keep alias
   for backward-compat one slice.
3. Add example in docstring showing maya→priya handoff.
4. Same review pass on `a2a_emit_message`, `a2a_update_status`,
   `a2a_cancel_task` — verify each verb conveys "I am the
   coordinator, not the executor" where applicable.

## Files

- `mcp-server/src/team_alpha_mcp/a2a/tools.py` (or wherever
  `a2a_send_task` lives — search `def a2a_send_task` /
  `@tool("a2a_send_task")`).

## Acceptance

- [ ] Docstring rewritten with explicit dispatch-vs-execute split.
- [ ] Maya in cold session dispatches without operator override on
      "Dispatch a terraform task: …" prompt.
- [ ] Other a2a_* tool docstrings audited.

## Refs

- `team-alpha-a2a-live-test-lightweight.md` — origin (T1).
- Session 2026-04-26 chat log.
