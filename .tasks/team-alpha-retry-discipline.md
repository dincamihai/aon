---
column: Backlog
created: 2026-04-25
order: 95
---

# Retry discipline — infra retries bounded, semantic waits = ASK humans

Capture and enforce a principle: agents and tools must NEVER retry forever
or flood the substrate with repeated messages. Two distinct categories:

| category | example | strategy |
|---|---|---|
| **infrastructure transient** | NATS reconnect, AUDIT mirror lag, KV CAS retry | bounded retry w/ backoff, 5s ceiling, then return error to caller |
| **semantic wait** | "task not claimed yet", "peer didn't reply", "human away" | NEVER retry. ASK chain: DM peer → DM coordinator → publish `state.alert.no_human` once. Stop. |

## Why

- Infinite retries on semantic waits = message flood, AUDIT bloat, no human signal
- Quiet failures = humans don't know they need to step in
- Stuck agents that bombard inboxes burn coordinator attention and erode the
  "if it's important you'll see it" trust property of the substrate

## Policy

1. **Infra retry budget: 5 seconds total.** After that, surface error to caller.
2. **Semantic ASK budget: 1 message per recipient per stuck-state.** If peer
   doesn't reply within timeout (10 min default), escalate ONCE to coordinator,
   then publish `state.alert.no_human` ONCE. After that, agent reports
   "blocked: stuck on human" in cycle output and stops working that thread.
3. **Tool defaults reflect (1)**: `recent_events` retries 3× with backoff
   (0.4s + 1.2s + 2.4s ≈ 4s); fewer is fine, more is a bug.
4. **Prompts enforce (2)**: each role's `_common.md` ASK-discipline section
   adds explicit "no flooding" rule.
5. **Detection**: coordinator-watcher (or new sub-detector) emits
   `state.alert.flood` if any role posts >5 inbox messages to same peer
   within 1 minute. Trips a circuit-breaker — peer's inbox sub deduplicates.

## Scope

### Updates to existing artifacts

- `scripts/agent-prompts/_common.md` — add §"Retry discipline" with the
  policy above.
- `mcp-server/src/team_alpha_mcp/client.py::recent_events` — add explicit
  comment + cap exposed via `MAX_RETRY_BUDGET_SEC = 5.0`.
- `mcp-server/src/team_alpha_mcp/__main__.py::dm` — track per-peer message
  count in process memory; refuse 6th message to same peer within 60s window
  (caller gets `ok: false, error: "flood guard"`); reset on reply received.

### New smoke / sim test

- `scripts/smoke/16-flood-guard.sh` — agent attempts 10 DMs to same peer in
  rapid succession; assert NATS records ≤5 then sender's tool returns
  flood-guard error.
- `scripts/sim/scenario-06-asking-humans.sh` — scripted: lin's human=busy,
  lin DMs raj (no reply), DMs maya (no reply), publishes
  `state.alert.no_human` ONCE, then stops. Assert audit shows exactly: 2
  DMs + 1 alert, no further publishes.

### Detection

- Optional: `coordinator-watcher.serve` mode subscribes live to
  `agents.*.inbox` w/ in-memory rolling window per (sender, peer) pair;
  emits `state.alert.flood` when threshold exceeded. P2.

## Acceptance

- [ ] `_common.md` documents the rule, every role prompt sources it.
- [ ] MCP `dm` tool enforces flood guard with clear error.
- [ ] `recent_events` retry budget capped at 5s.
- [ ] 16-flood-guard.sh passes.
- [ ] scenario-06-asking-humans.sh passes.
- [ ] Card 90 (human-availability) updated to reference this policy.

## Out of scope

- Server-side flood detection (NATS doesn't natively rate-limit per-publisher
  per-subject). Client-side enforcement is the layer that fits the shape of
  this team.
- Persistent flood state across restarts (in-memory window is enough for
  POC; if it leaks past restart, the new session re-arms cleanly).

## Refs

- card 90 (human-availability): semantic-wait state model
- card 110 (mcp-server): tool surface w/ baked-in defaults
- MODEL.md §"When to ASK": existing ASK chain language
