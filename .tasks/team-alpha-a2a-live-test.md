---
column: Backlog
created: 2026-04-26
order: 150
---

# A2A live integration testing (umbrella)

Sims 09-12 prove the wires programmatically. Live tests prove the
**agent UX** — that real LLM agents pick the right tools, parse
payloads, recover from errors, and read AUDIT correctly. Catches
prompt drift, tool-name confusion, payload-shape friction, ACL
error-message clarity.

Two phases by ceremony level.

## Subcards

| order | card | what |
|---|---|---|
| 151 | `team-alpha-a2a-live-test-lightweight.md` | 2-agent demo (maya + priya), one task end-to-end |
| 152 | `team-alpha-a2a-live-test-mob-session.md` | 6-agent mob, replays sims 01-12 with real LLMs |

## Acceptance (whole umbrella)

- [ ] Lightweight test passes; defects filed for any agent-UX
      surprises.
- [ ] Heavyweight session run; replay parity report (sim outcomes
      vs live outcomes).
- [ ] Tool docs / agent prompts updated with anything the live
      tests revealed.

## Refs

- `team-alpha-a2a-impl-slice3.md` — slice 3 closes MVP; live test
  validates it.
- `team-alpha-mcp-server.md` (card 110) — MCP host being exercised.
- `team-alpha-onboard.md` (card 30) — onboarding script used in 152.
