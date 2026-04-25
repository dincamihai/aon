---
column: Done
created: 2026-04-25
order: 110
---

# MCP server for coordinator + worker comms over NATS

Wrap the team-alpha protocol (subjects, KV, claim semantics, ASK chain) in an
MCP server so agents talk to the substrate via tool calls instead of raw `nats`
shell invocations. Same protocol, ergonomic API, server hides foot-guns.

## Why now

Discovered during smoke + sim build that the raw `nats` CLI has nontrivial
foot-guns. Agents using shell-out via prompts will trip over these. MCP server
encodes the right defaults once.

## Foot-guns the MCP server hides

(All learned from defects 201, 202, 203 + smoke iteration.)

| param / quirk | wrong choice | right choice (bake into tool) |
|---|---|---|
| `nats sub --timeout=5s` | silently ignored — sub blocks until count satisfied | use `--wait=5s` (only `--wait` bounds sub duration) |
| `--deliver=all` on AUDIT replay | scans entire history; old `{}` payloads drown recent slug events | `--deliver=60s` (configurable `since` param; default 60s for replay-style queries) |
| `--count=200` per consumer pull | recent events fall past window when AUDIT > 200 unrelated msgs | `--count=500` baseline; bump if >500 events per minute on a subject |
| `--filter='board.>'` (top-level wildcard) | matches too much, returns mostly noise | always use specific filter: `board.tasks.<domain>.<state>` or `board.results.<domain>.>` |
| ephemeral consumer name collision | two parallel callers with same name = pull race | name = `f"{prefix}-{pid}-{ns_ts}-{rand}"` enforced by tool |
| consumer cleanup on error | leak accumulates → server filter scan slows | `try/finally consumer rm -f` always |
| payload field name drift | events use `by` OR `role` OR `from` for emitter | tool emits canonical `by`; readers fallback `.by // .role // .from` |
| `nats sub --since` on workqueue subjects | doesn't replay reliably (TASKS, LEARNING are workqueue) | always pull from AUDIT (limits retention, mirrors all) for replay |
| KV write w/o `allow_responses` in ACL | request/reply via `$JS.API.>` times out | server-side ACL must include `allow_responses: true` + `_INBOX.>` subscribe; MCP server connects with these |
| AUDIT mirror lag after publish | immediate query misses just-published msg | tool waits ~500ms before AUDIT replay queries; configurable |
| `cluster {}` block in nats-server.conf w/ 0 routes | server refuses to start JetStream | omit cluster block for single-node; MCP server doesn't touch this (operator concern) |

Two classes of param the tool surface separates:

- **Per-action (stable, baked into tool defaults)**: consumer flags, count
  cap, wait bound, ack mode, replay policy, subject filter precision,
  payload schema.
- **Per-call (exposed as tool args)**: subject pattern, slug/task_id, payload
  content, lookback override.

## Tool surface

All tools async (FastMCP supports), authenticate as the role from env, return
structured JSON. ACL pre-check rejects locally before NATS roundtrip with a
typed error.

| tool | params | publishes / reads | notes |
|---|---|---|---|
| `claim_task` | `domain, slug` | `board.tasks.<domain>.claimed` + KV `agent.<role>.load` | rejects if domain not in role's `TASK_DOMAINS` |
| `block_task` | `domain, slug, reason` | `board.tasks.<domain>.blocked` | |
| `complete_task` | `domain, slug, sha, summary?` | `board.tasks.<domain>.done` + `board.results.<domain>.shipped` | rejects if `RESULTS_DOMAINS` denies role |
| `progress_task` | `domain, slug, note` | `board.tasks.<domain>.progress` | optional milestone marker |
| `post_task` | `domain, slug, summary, priority` | `board.tasks.<domain>.pending` | manager-only (`MANAGER`) |
| `park_task` | `slug, branch, reason` | KV `agent.<role>.parked` append + `board.tasks.*.parked` event | |
| `resume_task` | none | KV `agent.<role>.parked` LIFO pop + `board.tasks.*.resumed` event | empty-stack returns `ok: false` |
| `dm` | `peer, type, payload_json, request_reply?` | `agents.<peer>.inbox` | optional reply via `_INBOX.>` w/ 30s timeout |
| `broadcast_standup` | `agenda, time?` | `broadcast.standup` | manager-only |
| `broadcast_incident` | `severity, system, status, root_cause?, incident_id?` | `broadcast.incidents` | all roles can publish (defect-202 fix) |
| `broadcast_announcement` | `title, body` | `broadcast.announcement` | manager-only |
| `set_load` | `capacity, current_tasks?` | KV `agent.<role>.load` | role updates own |
| `set_human` | `status, scope?, until?, reason?` | KV `agent.<role>.human` + `state.agent.<role>.human` event | |
| `read_team_state` | `key` | KV `team-state.<key>` read | |
| `recent_events` | `subject, slug?, since="60s", limit=500` | AUDIT pull-consumer w/ filter | hides ephemeral consumer mgmt + replay tuning + cleanup |
| `offer_mentoring` | `domain, hours, topics[]` | `board.learning.<domain>.mentoring` | rejects if not in `MENTOR_DOMAINS` |
| `claim_learning` | `domain, slug` | `board.learning.<domain>.claimed` | rejects if not in `LEARNING_CLAIM_DOMAINS` |
| `post_learning` | `domain, slug, summary, scope_hours, mentor` | `board.learning.<domain>.pending` | senior + manager only |
| `set_policy` | `name, value_json` | KV `policy.<name>` + `state.policy.<name>` event | manager-only (HITL gate, delegate flag) |

### Default values tools use under the hood

```python
# Consumer creation (replay queries)
EPHEMERAL_FLAGS = dict(
    deliver_policy="by_start_time",   # ← bound replay window
    opt_start_time_default="60s",     # caller may override via `since`
    ack_policy="none",
    replay_policy="instant",
    inactive_threshold_sec=10,        # auto-GC if leaked
)
COUNT_CAP    = 500
WAIT_REPLAY  = 1.0   # seconds
WAIT_LIVE    = 5.0   # seconds for live req-reply

# Naming
def consumer_name(prefix: str) -> str:
    return f"{prefix}-{os.getpid()}-{time.monotonic_ns()}-{secrets.token_hex(2)}"

# Payload schema (canonical event)
def event_payload(slug: str, **extra) -> dict:
    return {
        "slug": slug,
        "by":   ROLE,                      # canonical emitter field
        "ts":   datetime.utcnow().isoformat() + "Z",
        **extra,
    }

# Reader fallback
EMITTER_JQ = '.by // .role // .from // "?"'
```

## Architecture

- Language: **Python**, FastMCP (`pip install mcp`).
- Transport: **stdio** by default (registered in `.claude/settings.json`); also
  supports **HTTP/SSE** for remote agent processes.
- Auth: connects as `$TEAM_ALPHA_ROLE` w/ password from
  `$TEAM_ALPHA_CREDS`. Token rotation = restart MCP server.
- Connection management: single shared `nats.Client`, lazily reconnect, KV
  client cached (`js.key_value("team-state")`).
- ACL pre-check: reads `acl.py` table (mirror of `nats/auth.conf`) before
  publish. Returns typed error including allowed scope.
- Subject taxonomy: `subjects.py` is the single source. Tools never hardcode.

## Files

```
mcp-server/
  pyproject.toml
  README.md
  src/team_alpha_mcp/
    __init__.py
    __main__.py        # entry: argparse, FastMCP wiring, stdio/http selection
    subjects.py        # subject taxonomy constants
    acl.py             # role → allowed-domain tables + can_X(role, ...) checks
    client.py          # nats connection wrapper, KV client, audit replay helper
    tools/
      __init__.py
      tasks.py         # claim/block/complete/progress/post
      learning.py      # claim_learning/offer_mentoring/post_learning
      comms.py         # dm/broadcast_standup/broadcast_incident/broadcast_announcement
      state.py         # set_load/set_human/set_policy/read_team_state
      replay.py        # recent_events
      preempt.py       # park_task/resume_task
  tests/
    test_acl.py        # static unit tests on acl tables
    test_smoke.py      # spin up against running substrate
```

## Acceptance

- [ ] All tools defined w/ JSON schemas via FastMCP's `@mcp.tool()` decorator.
- [ ] Per-role ACL enforced client-side: `claim_task("python", ...)` as Sam
      returns typed error, no NATS publish attempted.
- [ ] Tools publish canonical payload (`{slug, by, ts, ...}`); reader tools
      tolerate legacy field names via fallback.
- [ ] `recent_events` works against AUDIT, replay window bounded by `since`
      param (default 60s), no leaked ephemeral consumers.
- [ ] Server starts via `team-alpha-mcp` CLI, registers in
      `.claude/settings.json` MCP block.
- [ ] Unit tests on `acl.py` (no NATS needed).
- [ ] Integration smoke test reuses the running substrate; spins up server,
      calls each tool once, asserts non-error.
- [ ] Documentation in `mcp-server/README.md`: install, env vars, register
      with Claude Code, map MCP tool → underlying NATS subject for debugging.
- [ ] No client-side audit dual-write — AUDIT stream remains source of truth.

## Smoke test scenarios (after server lands)

Re-run `scripts/sim/run-all.sh` BUT each role in the scenarios uses MCP tools
instead of `nats` CLI. Validates the server is functionally equivalent to the
raw protocol — same scenarios pass, same defects rejected, same audit shape.

Add `scripts/sim/scenario-06-mcp-equivalence.sh` (calls MCP server tools
via a small Python client harness) once server is live.

## Depends_on

- defect-201 (watcher AUDIT replay) — DONE
- defect-203 (replay window bound) — DONE; `recent_events` reuses the same
  `--deliver=<since>` pattern
- agent-prompts (50) — DONE; prompts will be updated post-MCP to recommend
  tools instead of raw `nats` shell

## Out of scope

- Replacing `nats` CLI for the operator (still raw shell for ops).
- Multi-role single-server (one server process per role; simpler isolation).
- Live event push to MCP client (current scope is request/response tools;
  if agent wants live stream, it still uses Claude Code Monitor on `nats sub`).
