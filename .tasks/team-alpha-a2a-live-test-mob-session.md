---
column: Backlog
created: 2026-04-26
order: 152
---

# Live test — full mob session (all six roles)

Replay sims 01-12 with real LLM agents driving each role. Validates
the prompts, onboarding scripts, and ergonomic flow of a complete
team day.

Run only after card 151 (lightweight) is green. This is heavier
ceremony — six terminals, real attention to drift.

## Setup

### 1. Onboard all six roles

For each role in `{maya, raj, lin, sam, diego, priya}`:

```bash
TEAM_ALPHA_ROLE=$role \
TEAM_ALPHA_NATS_URL=nats://localhost:4222 \
TEAM_ALPHA_CREDS=~/.team-alpha/$role.password \
bash scripts/onboard.sh $role
```

(Existing onboard script — emits handshake, KV load, prompt fallback.)

### 2. Six Claude Code sessions

Each in its own terminal/tmux pane. Per-role MCP server registered.
Each session reads `scripts/agent-prompts/<role>.md` as system-style
context (or pasted into the first turn).

### 3. AUDIT + watcher dashboard

Two more panes:
- `nats sub 'a2a.>,board.>,state.alert.>' --raw`
- `coordinator-watcher.sh serve` (live tick, alerts to stdout)

## Replay scenarios

For each sim/scenario already passing in the bash harness, reproduce
the prompt + expected behavior with real agents:

| sim | live prompt seed |
|---|---|
| 01 — normal task | maya posts terraform; priya picks up |
| 02 — cross-functional | maya posts fullstack; raj or lin pulls + DMs specialists |
| 03 — permission reject | maya posts python; sam tries to claim → ACL deny → falls back to learning |
| 04 — incident | priya broadcasts AWS incident; raj DMs to help |
| 05 — mentoring | raj offers go mentoring; lin grabs slot |
| 06 — asking humans | sam DMs diego inbox; diego replies on his own surface |
| 07 — preempt flow | maya pushes high-priority; lin parks her current; resumes later |
| 08 — delegated scope | lin operator sets delegation scope=python; maya posts UI → HITL gate |
| 09 — A2A push dispatch | maya `a2a_send_task` skill=terraform; priya auto-accepts |
| 10 — A2A streaming | priya emits `.message` chunks during long task |
| 11 — A2A cancel | maya cancels in-flight task; priya lifecycle transitions |
| 12 — dual-write parity | substrate flow + bridge mirror; AUDIT carries both |

## What we're measuring

- **Tool drift**: do agents pick `claim_task` vs `a2a_send_task`
  appropriately (push vs pull / directed vs broadcast)?
- **Prompt accuracy**: are role prompts up to date post-cards-131-143?
  Spot any reference to deprecated KV `agent.<role>.skills`.
- **DM flood guard** (card 95): does it trip during real escalation?
- **Watcher signal-to-noise**: false positives in `a2a_stale`?
- **Mentor pairing**: does raj actually offer mentoring without
  prompt babysitting?
- **HITL gate latency**: how long does Lin wait for her human's
  ack before timing out?

## Deliverables

- `docs/mob-session-2026-XX-runbook.md` — chronological log,
  one entry per sim.
- Replay parity report: pass/fail per sim, prompts captured.
- Defect cards for every drift (one per friction).
- Updated `scripts/agent-prompts/<role>.md` if prompts need clarity.

## Acceptance

- [ ] All 12 scenarios run with real agents; outcomes match sim
      harness ≥80% (some natural-language variance expected).
- [ ] Defect cards filed for divergences.
- [ ] At least one prompt revised based on observed friction.
- [ ] Runbook checked in.

## Out of scope

- Multi-org cross-team mob (post-MVP; needs account exports).
- HTTP+SSE bridge flows (post-MVP).
- Stress test (separate post-MVP card).

## Refs

- `team-alpha-a2a-live-test.md` — umbrella.
- `team-alpha-a2a-live-test-lightweight.md` — gate card 151 first.
- `team-alpha-mcp-server.md` (110) — host.
- `team-alpha-onboard.md` (30) — onboarding flow.
- `team-alpha-agent-prompts.md` (50) — prompt sources.
