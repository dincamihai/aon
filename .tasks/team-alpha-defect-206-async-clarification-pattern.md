---
column: Done
created: 2026-04-26
order: 206
---

# Defect 206 — Dispatcher agent over-collects specs instead of using async clarification

**Fixed 2026-04-26.** Maya role prompt + priya role prompt updated
with A2A dispatch + workflow sections. `a2a_send_task` docstring
rewritten (defect 205). `a2a_emit_message` docstring rewritten with
"PRIMARY USE — async clarification with the dispatcher" lead +
concrete example. Real-Claude retest queued for next session.

Observed in card 151 lightweight live test, T1 (after defect 205 fix-bypass).

## Symptom

After being told dispatch is safe, Maya enumerated 8 questions
(peer VPC IDs, regions, accounts, CIDRs, DNS, repo path, priority,
mode) before sending. Operator had to coach her to dispatch
minimal-payload and let priya request clarifications via
`a2a_emit_message` after accept.

## Root cause

Agent prompt / tool docs do not describe the async clarification
loop:

- Sender ships minimal viable payload.
- Receiver accepts, then `a2a_emit_message(task_id, role="assistant",
  content="need <X>")` to ask back.
- Sender replies via same message channel.
- Receiver completes.

Without that pattern stated, agents fall back to synchronous-Q&A
through the human operator — defeats A2A.

## Fix

1. `mcp-server/src/team_alpha_mcp/agent_prompts/<role>.md` (or
   wherever the dispatcher system prompt lives): add "Dispatch
   pattern" section. Bullet the minimal-payload + receiver-asks-via-
   message flow. Concrete example.
2. `a2a_send_task` docstring: add "Send minimal payload. Receiver
   can request clarifications via `a2a_emit_message` after accept —
   do not pre-collect specs from operator."
3. `a2a_emit_message` docstring: lead with "primary use is async
   clarification between sender and receiver during task lifecycle."

## Acceptance

- [ ] Cold maya session, given "Dispatch a terraform task: add
      staging VPC peering," sends within 1 turn with summary-only
      payload.
- [ ] Cold priya session, after accepting, asks for missing details
      via `a2a_emit_message` rather than completing-with-nulls or
      asking the operator.

## Refs

- `team-alpha-defect-205-a2a-send-task-docstring.md` — sibling.
- `team-alpha-a2a-live-test-lightweight.md` — origin.
