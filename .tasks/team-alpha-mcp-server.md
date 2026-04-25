---
column: Backlog
created: 2026-04-25
order: 110
---

# MCP server for coordinator + worker comms over NATS

Wrap the team-alpha protocol (subjects, KV, claim semantics, ASK chain) in an
MCP server so agents talk to the substrate via tool calls instead of raw `nats`
shell invocations. Same protocol, ergonomic API.

## Premise

Currently each role's agent shells out to `nats pub` / `nats sub` / `nats kv`.
That works but has rough edges:
- payload JSON construction in shell is error-prone
- subject taxonomy lives in prompts as prose, not code
- per-role ACL boundaries surface only at server-side rejection, no client-side
  introspection
- no schema validation client-side (validation gateway is server-side only)

An MCP server for each role (or one server with a `role` parameter) exposes
typed tools matching the protocol. The server runs as a subprocess of the
Claude session, authenticates as the role, and brokers all NATS comms.

## Tool surface (sketch)

| tool | purpose |
|---|---|
| `claim_task(domain, slug)` | publish `board.tasks.<domain>.claimed`, update KV load |
| `post_task(domain, payload)` | manager-only — publish `board.tasks.<domain>.pending` |
| `block_task(domain, slug, reason)` | publish `board.tasks.<domain>.blocked` |
| `complete_task(domain, slug, sha)` | publish `board.tasks.<domain>.done` + `board.results.<domain>.shipped` |
| `park_task(slug, branch, reason)` | append parked KV + publish `parked` event |
| `resume_task()` | pop parked stack LIFO + publish `resumed` event |
| `dm(peer, payload)` | publish to `agents.<peer>.inbox` w/ request-reply |
| `broadcast_standup(agenda)` | manager-only — `broadcast.standup` |
| `broadcast_incident(severity, system, status, root_cause?)` | `broadcast.incidents` |
| `set_load(capacity)` | KV `agent.<self>.load` |
| `set_human(status, scope?, until?)` | KV `agent.<self>.human` |
| `read_team_state(prefix)` | KV mirror read |
| `recent_events(subject, since)` | replay from AUDIT stream (uses fix from defect-201) |
| `offer_mentoring(domain, hours, topics)` | senior-only — `board.learning.<domain>.mentoring` |
| `claim_learning(domain, slug)` | growth-track claim |

Each tool:
- has typed JSON schema parameters
- validates against role's ACL (rejects locally with helpful error before
  hitting server)
- emits structured payload with required fields (`task_id`, `slug`, `by`,
  `ts`, etc.)
- returns request-reply result where applicable (e.g. DM with reply)

## Implementation

- Language: Python (FastMCP) or TypeScript (MCP SDK). Python preferred — we
  already have nats-py available; matches membrain stack.
- Single server binary, role passed via env `TEAM_ALPHA_ROLE` at startup.
- Authentication: connects with role's password from `$TEAM_ALPHA_CREDS`.
- Each tool emits a single NATS publish (or KV op); AUDIT mirrors. No client
  dual-write.
- Schema validation done locally + server validation gateway for defense in
  depth.

## Files (when implemented)

- `mcp-server/team-alpha-mcp/` — Python package
  - `__main__.py` — entrypoint
  - `subjects.py` — subject taxonomy as constants
  - `acl.py` — per-role allow/deny tables (mirrors `nats/auth.conf`)
  - `tools/` — one module per tool, JSON schema + handler
  - `client.py` — nats connection wrapper, KV client, retry logic
- `mcp-server/README.md` — install, configure, register with Claude Code
- `.claude/settings.json` — add MCP server registration block
- `mcp-server/tests/` — pytest tests w/ in-memory NATS (or mock)

## Acceptance

- [ ] All tools defined w/ schemas + handlers.
- [ ] Per-role ACL enforced client-side (Sam calling `claim_task("python", ...)`
      gets a typed error before NATS roundtrip).
- [ ] Each tool publishes the canonical payload shape; tests validate against
      schema.
- [ ] Registered in Claude Code, agent calls `mcp__team_alpha__claim_task` and
      it works end-to-end against a running substrate.
- [ ] Tools that need replay (recent_events) use AUDIT-stream pull consumer
      (depends on defect-201 fix).
- [ ] Documentation describes how to add a new subject without regenerating
      ACLs (single source of truth in `subjects.py`).

## Depends_on

- defect-201 (watcher history replay) — for `recent_events` tool to work.
- agent-prompts (50) — DONE — server's tool descriptions inform prompt copy.

## Out of scope

- Replacing the `nats` CLI for shell users (operator still uses raw CLI for
  ops).
- Multi-role single-server (one server per role agent process is simpler).
