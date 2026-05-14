---
column: Backlog
created: 2026-05-14
order: 169
---

# A2A HTTP+SSE bridge (external federation)

The team-alpha A2A protocol runs natively over NATS. The Google A2A
spec (https://google.github.io/A2A) uses HTTP + Server-Sent Events.
Without a bridge, team-alpha agents cannot interop with external A2A
agents (other orgs, tools, or heterogeneous runtimes).

## Deliverables

### 1. Inbound bridge (external → NATS)

HTTP server (FastAPI or aiohttp) exposing the A2A spec endpoints:

- `POST /tasks/send` → validates payload, translates to
  `a2a.<target>.tasks.send` NATS request-reply, returns ack.
- `GET  /tasks/{task_id}/status` → reads from `A2A_TASKS` JetStream,
  returns current state.
- `GET  /tasks/{task_id}/events` (SSE) → subscribes to
  `a2a.*.tasks.<task_id>.status` + `.message`, streams events to
  caller as `text/event-stream`.

Auth: bearer token mapped to a NATS creds file via a config map
(`bridge.yaml`). No anonymous access.

### 2. Outbound bridge (NATS → external)

When dispatcher routes a task to an externally-registered role
(role card has `endpoint.url` set and `auth.scheme = bearer`):
- POST the task to the external agent's `/tasks/send`.
- Poll or subscribe to their SSE stream for status updates.
- Mirror updates back into local `A2A_TASKS` JetStream under a
  synthetic `a2a.external.<role>.tasks.<id>.status` subject.

### 3. Role card extension

Add optional fields to `agents/<role>.json`:
```json
"endpoint": { "url": "https://...", "auth": "bearer" }
```
`dispatcher.py` reads `endpoint.url`; if set, routes via outbound
bridge instead of NATS `tasks.send`.

### 4. `aon launch` integration

Start bridge server as background process when
`AON_A2A_BRIDGE_PORT` env is set. Default disabled.

### 5. Smoke 23

`scripts/smoke/23-a2a-http-bridge.sh`:
- Start bridge on localhost ephemeral port.
- POST a task via HTTP; assert NATS `tasks.send` received.
- Emit status update via NATS; assert SSE stream delivers event.
- Verify auth rejects unauthenticated POST.

## Acceptance

- [ ] Smoke 23 green.
- [ ] Round-trip latency HTTP→NATS→HTTP <200 ms on loopback.
- [ ] No NATS creds exposed in HTTP responses or logs.
- [ ] Disabled (no port bound) when `AON_A2A_BRIDGE_PORT` unset.

## Refs

- `team-alpha-a2a-investigation.md` §Library — original deferred note.
- `mcp-server/src/aon_mcp/a2a/dispatcher.py` — routing point.
- `agents/*.json` — card format to extend.
- Google A2A spec: https://google.github.io/A2A
