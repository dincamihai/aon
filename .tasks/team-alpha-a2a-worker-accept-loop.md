---
column: Backlog
created: 2026-04-26
order: 131
---

# A2A worker auto-accept loop

Slice 1 shipped the dispatcher (Maya-side `a2a_send_task`) but no
worker-side receive surface. End-to-end isn't possible without this:
Maya publishes on `a2a.<role>.tasks.send`, the worker MCP server
needs to subscribe, validate, ack, and publish the first
`.status = working` event.

## Deliverables

### 1. Subscription on MCP-server startup

In `team_alpha_mcp/__main__.py`, after `client = TeamAlphaClient(...)`,
spawn a background subscription task on `a2a.<ROLE>.tasks.send` for
worker roles only (skip when `ROLE == "maya"`). Lives for the MCP
server's lifetime.

### 2. Handler: `team_alpha_mcp/a2a/worker.py`

- `start_accept_loop(client, role)` — subscribe + dispatch incoming
  `tasks/send` requests. Use `nc.subscribe(subject, cb=...)` with
  ack-via-reply pattern.
- For each request:
  1. validate via `schemas.validate_task_send` (reject on schema fail
     with reply `{"ok": false, "error": ...}`).
  2. confirm advertised skill match (defensive — server ACL is per-
     role, but slice 1 trust model is honor-system; worker re-checks).
     Reject if `skill` not in own card's skills.
  3. publish initial `.status = working` on
     `a2a.<self>.tasks.<task_id>.status` (lifecycle from submitted).
  4. reply on _INBOX with `{"ok": true, "task_id": ..., "accepted_by":
     <role>}`.
  5. queue actual task work for the agent (slice 2 just records to
     local in-memory dict; slice 3 wires into agent prompt).

### 3. KV state for in-flight A2A tasks

Add KV key `a2a.<role>.inflight = {<task_id>: {state, since, payload}}`.
Worker writes on accept; updates on each `a2a_update_status` call;
clears on terminal state. Replaces the "slice 1 caller tracks"
note in `a2a_update_status` — server-side state KV.

### 4. Tool surface

- `a2a_accept_task(task_id, ...)` becomes optional explicit re-ack;
  default flow is auto-accept via the loop.
- `a2a_update_status` reads `from_state` from inflight KV instead of
  caller-supplied default.

### 5. Smoke addition

Extend `scripts/smoke/17-a2a-roundtrip.sh` (or new 17b): start two
MCP servers via subprocess, Maya dispatches, Priya auto-accepts,
status flows through to completed. Assert AUDIT chain.

## Acceptance

- [ ] Worker MCP server subscribes on startup, runs accept loop.
- [ ] Round-trip smoke green: Maya dispatch → Priya accept → status
      working → completed; AUDIT shows full chain.
- [ ] Schema-fail dispatch returns reply error, no `.status` event.
- [ ] Skill-mismatch dispatch (e.g. Maya sends skill="nonexistent")
      handled cleanly via dispatcher (no candidate found).

## Refs

- `team-alpha-a2a-impl-slice2.md` — umbrella.
- `team-alpha-a2a-impl-slice1.md` — dispatcher delivered there.
