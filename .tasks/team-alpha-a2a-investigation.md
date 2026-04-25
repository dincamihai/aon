---
column: Backlog
created: 2026-04-25
order: 120
---

# Investigate adopting Google A2A protocol on the NATS substrate

A2A (Agent-to-Agent Protocol, Google, 2024) is a vendor-neutral spec for
agent coordination: capability-based routing, formal task lifecycle,
identity + auth, schema enforcement. It addresses several gaps in the
current ad-hoc protocol.

## Why this fits "any size"

| Need | A2A delivers |
|---|---|
| Capability-based routing (not name-based) | Agent cards advertise skills; coord routes by skill match |
| Formal task lifecycle | `submitted → working → input-required → completed/failed/canceled` — direct map to our column states |
| Identity + auth per agent | Agent cards include auth schema; OAuth / API-key / mTLS supported |
| Protocol versioning | Built into agent card |
| Long-running tasks + streaming updates | SSE (HTTP) or push-notification webhooks |
| Heterogeneous agents (Claude / qwen / GPT / etc.) | Vendor-neutral spec |
| Discovery | `.well-known/agent.json` endpoint pattern |
| Schema enforcement | JSON-RPC + JSON Schema for messages |

## What this changes

- **Coord** becomes an A2A client (sends tasks). **Workers** become A2A
  servers (each exposes `/.well-known/agent.json` + task endpoints).
- Each worker publishes a card listing its skills (e.g. `rust-port`,
  `python-mage`, `docs`, `unit-tests`). Replaces hand-edited
  `assignee:` field on cards.
- Coord matches card → assigns task by capability match.
- Network model inverts (in pure HTTP A2A): coord initiates HTTP to
  workers. Cloudflared / VPN / NATS subjects all viable transports.

## What survives

- Task cards in repo (`.tasks/*.md`) → become A2A task descriptors
- Git as audit log → keep, A2A doesn't replace it
- ADR / process docs → unchanged
- NATS as transport (A2A is transport-agnostic; default is HTTP+SSE,
  pub/sub also valid)

## Mapping A2A primitives → NATS subjects

A2A is JSON-RPC payloads; NATS gives request-reply + JetStream replay,
which fits the lifecycle model.

| A2A primitive | NATS subject pattern |
|---|---|
| `tasks/send` | `a2a.<agent>.tasks.send` (request-reply) |
| Task status updates | `a2a.<agent>.tasks.<task_id>.status` (stream) |
| Streaming message chunks | `a2a.<agent>.tasks.<task_id>.message` |
| Agent card discovery | `a2a.discovery.<agent_id>` (req-reply) or static catalog subject |
| Auth | NATS user/JWT maps to A2A auth schema |

Implementation details to verify:

- **Request-reply**: NATS reply-to inbox = JSON-RPC `id` correlation
- **At-least-once**: JetStream for task subjects; ephemeral OK for status
- **Backpressure**: SSE replacement = consumer pull from JetStream
- **Cancellation**: `tasks/cancel` → companion subject + cleanup

## Investigation questions

1. Vendor-neutrality: is the A2A spec stable enough? Reference impls?
2. Skill grammar: free-form strings or registered taxonomy? Conflict with
   our domain list (`python|ui|go|terraform|aws|fullstack|review`)?
3. ACL: per-skill in addition to per-role? How does this layer on
   `nats/auth.conf`?
4. Migration cost: dual-run NATS-native + A2A-on-NATS; cutover one event
   type at a time. Estimate 1-2 weeks for full cutover.
5. Tool fit: does MCP server (card 110) wrap A2A or replace it? Best
   answer is probably: MCP tools call A2A under the hood; agent doesn't
   know.
6. Cloud transport: Synadia Cloud (managed NATS, JWT auth, free tier 1GB
   storage / 10GB egress / 4 conns) vs self-host on EKS w/ NATS Helm
   chart (~$200/mo baseline). Migration is just URL/creds change.
7. Card lifecycle binding: A2A states map to our `column:` field cleanly?
   `submitted=Backlog, working=InProgress, input-required=Blocked,
   completed=Done`. Verify with full task journey.

## What this card produces

- `docs/a2a-investigation.md` — answers the questions above with
  references, lays out 3 paths (adopt now / partial / never)
- `nats/a2a-subjects-example.md` — sketch of subject taxonomy if adopted
- (optional) `mcp-server/src/team_alpha_mcp/a2a_adapter.py` — proof-of-
  concept wrapping current tools as A2A endpoints

## Acceptance

- [ ] Investigation doc exists and answers all 7 questions.
- [ ] Decision recorded: adopt now / partial / defer / never, with
      reasoning grounded in observed pain points after 2-4 weeks of real
      team use of the current substrate.
- [ ] If adopt: subsequent card scopes implementation + cutover plan.
- [ ] If defer / never: doc records reason so future engineers don't
      relitigate the decision.

## Out of scope

- Implementation (this card = investigation only).
- Replacing card files / git audit (those survive any A2A move).

## Refs

- A2A spec (Google, 2024): https://github.com/google/A2A
- card 110 (mcp-server): tool surface that A2A could either wrap or
  underlay.
- card 80 (github-cards-workflow): A2A formal lifecycle is the natural
  fit for task cards.
- Synadia Cloud (managed NATS): https://www.synadia.com/cloud
- NATS Helm chart (self-host on k8s): https://github.com/nats-io/k8s
