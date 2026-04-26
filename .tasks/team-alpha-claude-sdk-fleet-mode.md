---
column: Backlog
created: 2026-04-26
order: 219
---

# Card 219 — Claude Agent SDK fleet mode (post-HITL)

> **Status (2026-04-26):** Superseded by Card 220
> (`team-alpha-post-mvp-delegate-sdk-architecture.md`). The pivot
> to `/delegate` + ephemeral SDK containers makes this fleet-mode
> story redundant — every worker becomes SDK-based by default.
> Keep this card archived for the rationale; do not implement
> separately.

Currently every role runs the interactive `claude` CLI inside its
container (card 214). That's the right call while team-alpha is
human-in-the-loop: the operator wants to read the agent's chat,
correct it mid-flight, drop into a tab.

Once we move past HITL — autonomous workers spawned by maya, no
human reading priya's transcript — the CLI's interactive shape
becomes overhead. Replace per-role CLI sessions with Claude Agent
SDK processes.

## When this card unlocks

Triggered by either:

- A "delegated" KV policy that holds for hours/days at a stretch
  (workers run continuously, no human reads each turn).
- A scale point where 5+ concurrent active roles becomes load-y
  to operate as 5 interactive panes.

Until then, this card stays parked.

## Spec sketch

- Replace `claude` binary as PID 1 in the worker container with
  a small Python service that uses Claude Agent SDK.
- Keep every input/output contract the CLI gave us:
  - SessionStart-equivalent: emit `agents.<role>.events
    {kind:"hello", ts}` + run catch-up.
  - PostToolUse-equivalent: status ping + context refresh.
  - Stop-equivalent: end-of-turn cursor bump.
- MCP servers stay registered the same way (Agent SDK supports
  MCP).
- Role brief delivered as the system prompt instead of CLAUDE.md
  auto-load.
- Maya MUST stay on CLI in HITL mode; she only flips to SDK if
  the whole team flips.

## Out of scope

- Multi-tenant SDK fleets (one host, many users).
- Removing card 214 (CLI mode is still the dev/HITL default).

## Acceptance

- [ ] Worker container runs without `claude` CLI, fully headless.
- [ ] All hook semantics from cards 60/210/212 reproduced via SDK
      callbacks (or replaced by an explicit equivalent).
- [ ] Context window + cost monitoring exposed via `agents.<role>.events`.
- [ ] Switch is per-role (env or compose flag), not global —
      lets us run priya headless while diego stays HITL.

## Refs

- Card 214 — current CLI-in-container baseline.
- Anthropic Claude Agent SDK docs (TypeScript + Python).
