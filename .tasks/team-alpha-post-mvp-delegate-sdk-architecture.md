---
column: Backlog
created: 2026-04-26
order: 220
---

# Card 220 — Post-MVP architecture: /delegate + Claude Agent SDK + ephemeral containers

**Status: deferred post-MVP.** Captures the architectural pivot we
agreed on 2026-04-26 *after* card 214 slice 1 landed. Supersedes
the long-running per-role CLI container model in card 214 slices
2–5 and absorbs card 219 (SDK fleet mode).

## Why pivot

Card 214 modeled each worker role as a long-running `claude` CLI
session inside its own container, attached via `docker exec` for
HITL. That works, but:

- Six idle CLI sessions burn tokens + load on Anthropic API even
  when no work is happening.
- Worker identity is artificial — priya doesn't actually persist
  across tasks; her useful state is in NATS.
- HITL inside each worker container = the operator opening N panes
  and switching between role personas. Friction grows linearly
  with team size.
- Maya the dispatcher overlaps with what the operator's *own* host
  CLI session already does (read board, decide who, kick off).

The cleaner shape: the **operator + their host CLI persona is the
coordinator.** Workers are ephemeral SDK invocations spawned via a
`/delegate` skill, container-per-task, disposed on completion.

## New shape

```
┌────────────────────┐
│ Host: operator + ──┼──/delegate(task-card)──┐
│ their claude CLI   │                        │
└────────────────────┘                        ▼
        ▲                              ┌─────────────────┐
        │   NATS substrate (audit)     │ ephemeral       │
        └──────────────────────────────│ container w/    │
                                       │ Claude Agent SDK│
                                       │ runs role brief │
                                       │ exits on done   │
                                       └─────────────────┘
```

Components:

- **Host CLI session** — operator + persona. Owns the board, watches
  AUDIT, calls `/delegate` to dispatch, consumes results.
- **`/delegate <slug>` skill** — adapted from the existing qwen
  delegate skill. Reads the task card, picks role by skill match,
  spawns a container w/ Claude Agent SDK and the role's system
  prompt. Returns the structured artifact when SDK exits.
- **Ephemeral worker container** — built FROM team-alpha-worker-base
  (slice 1, already shipped). PID 1 = a small Python entrypoint
  that drives Claude Agent SDK. No persistent claude session.
- **NATS substrate** — unchanged. Workers still publish to
  `agents.<role>.events`, `a2a.<role>.tasks.<id>.status`, etc.
  Operator's CLI session reads via Monitor.
- **No maya runtime persona.** Maya remains in archived
  simulation cards as the dispatcher prop. Live coordination =
  the operator + their host persona.

## What survives from current state

| Artifact                                  | Verdict          |
|-------------------------------------------|------------------|
| `infra/worker-image/Dockerfile.base`      | Reused — SDK installs alongside (or replaces) claude CLI |
| `infra/worker-image/build.sh`             | Reused as-is    |
| Hook scaffolding (cards 60/210/212)       | Replaced by SDK lifecycle callbacks (on_start, on_tool_use, on_stop) |
| Role briefs `scripts/agent-prompts/<role>.md` | Reused — passed as SDK system prompt at spawn time |
| `_common.md`                              | Reused          |
| MCP servers (`team-alpha-mcp`, board-tui) | Reused — registered in SDK config |
| Card 211 (role-monitor wrapper)           | Reused for the *operator's* host CLI session, not workers |
| Card 213 (runtime task board)             | Reused — board is the work queue, operator's persona reads it |
| Card 217 (maya done-mover)                | Becomes trivial — SDK return value is structured, the operator's persona moves the card directly |
| Card 218 (README bootstrap)               | Re-sequence: depends on 220 landing, not 214 |
| Card 219 (SDK fleet mode)                 | **Superseded.** Mark Done as superseded once 220 lands |

## What changes

- Drop `claude` CLI from the worker container; install Claude Agent
  SDK (Python — `pip install anthropic-agent-sdk` or whatever the
  v1 package is). Keep claude CLI on host only.
- `claude --resume` / per-role `.claude/settings.json` stamps —
  no longer relevant for workers; only operator's host session
  uses them.
- `compose.workers.yml` — not needed. `/delegate` invokes
  `docker run --rm -e ROLE=priya -e TASK_SPEC=... worker-image:base`
  per task.
- Per-role tooling overlays (Dockerfile.<role>) — same YAGNI rule
  as before. Add when a real task needs real binaries.
- Maya container, maya `.claude/settings.json`, maya MCP — drop.
  Operator's own host CLI takes the dispatcher role.

## Spec — slices

### Slice 1 — SDK entrypoint

`infra/worker-image/sdk-entrypoint.py`

Reads from env:
- `TEAM_ALPHA_ROLE` — picks role brief.
- `TASK_SPEC` (json) — `{task_id, slug, summary, card_path, acceptance, payload}`.
- `ANTHROPIC_API_KEY` — via secret mount.
- `TEAM_ALPHA_NATS_URL` + `TEAM_ALPHA_CREDS` — via secret mount.

Loads `/etc/team-alpha/agent-prompts/<role>.md` + `_common.md` as
system prompt. Loads `_common.md` shared. Configures MCP servers
(team-alpha + board-tui-role-filtered). Runs SDK loop with the task
prompt (summary + acceptance + card_path). On agent stop, structured
result printed to stdout (json). Container exits.

### Slice 2 — `/delegate` extension

Extend the existing `/delegate` skill (or fork as `/delegate-sdk`)
to:

1. Read task card from board (slug → `~/team-alpha-board/inbox/<slug>.md`).
2. Resolve role: explicit `target:` frontmatter or skill match.
3. Mint short-lived NATS creds (or use static role password at v1).
4. `docker run --rm` worker image with secrets + env + task spec.
5. Capture stdout json, write `## Result` to card, move to `done/`.

### Slice 3 — SDK lifecycle → NATS

Reproduce hook semantics inside the SDK entrypoint:

- on_start → publish `agents.<role>.events {kind:"hello", task_id, ts}`.
- on_tool_use → status ping (rate-limited per kind, like card 212).
- on_stop → cursor bump, final status emit, structured result.

### Slice 4 — Retire maya runtime

- Remove `~/team-alpha/maya/` workdir from install scripts.
- Drop maya from role-monitor wrapper subscriptions.
- Update `_common.md` and `MODEL.md`: maya = simulation prop, not
  a live persona. Coordinator = operator + their host CLI.

### Slice 5 — Operator's host CLI integration

- Operator's `.claude/settings.json` (host-side, repo root)
  registers the `team-alpha` MCP + board-tui MCP.
- Operator's persona reads `MODEL.md` + a coordinator brief.
- `/delegate` is the verb; everything else (board state, AUDIT,
  done card moves) flows through MCP tools.

## Out of scope for this card

- Multi-host worker deployment (k8s, swarm).
- Pool of warm SDK workers (start cold; revisit if startup latency
  becomes a problem).
- gVisor / Kata sandboxing (still post-MVP P3).
- True secret-less containers via short-lived JWTs — slice 2
  starts with mounted role passwords; tighten to JWTs in a
  follow-up card.

## Acceptance

- [ ] Operator runs `/delegate tb-2026-...-something`. A container
      spawns, runs the role's SDK loop, completes, moves the card
      to `done/` with `## Result` populated. No persistent role
      session anywhere.
- [ ] AUDIT trace shows the same shape as today (status events,
      results) — only the producer is the SDK callback, not a CLI
      hook.
- [ ] Operator can attach to the SDK container's stderr in real
      time (`docker logs -f`) for HITL observation.
- [ ] Killing the container mid-task → operator's persona detects
      the gap (no completion event within deadline) and re-queues
      the card. (May need card 217's logic moved to host side.)
- [ ] Image rebuild < 60s incremental.

## Refs

- Card 214 — original CLI-in-container plan; slices 2–5 superseded
  by this card.
- Card 219 — SDK fleet mode; absorbed into this card.
- Card 217 — maya done-mover; rewrite as host-side mover under 220.
- Existing `/delegate` skill — pattern source.
- Anthropic Claude Agent SDK docs — TS + Python.

## Decision log

- 2026-04-26: pivot from per-role CLI containers to ephemeral SDK
  containers driven by host `/delegate`. Reasoning: (a) operator
  is the only real coordinator; maya was a simulation artifact;
  (b) idle CLI sessions waste tokens; (c) ephemeral SDK matches
  the "task in, artifact out" mental model better.
- Containerization implementation deferred post-MVP. Slice 1 (base
  image + build.sh) already shipped — small enough to sit idle
  until 220 picks it up.
