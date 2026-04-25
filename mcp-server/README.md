# team-alpha-mcp

MCP server wrapping the team-alpha NATS coordination protocol. Each role
agent runs one server process that exposes typed tools for the protocol —
no raw `nats` shell required.

See `.tasks/team-alpha-mcp-server.md` for design notes and the foot-gun
table this server hides.

## Install

```bash
cd mcp-server
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
```

Requires Python ≥3.10.

## Configure (per role)

Same env vars as the rest of the substrate:

```bash
export TEAM_ALPHA_ROLE=lin
export TEAM_ALPHA_NATS_URL=nats://nats.team-alpha.corp:4222
export TEAM_ALPHA_CREDS=$HOME/.team-alpha/lin.password
```

## Run

```bash
team-alpha-mcp                       # stdio (default — for Claude Code)
team-alpha-mcp --transport http      # HTTP/SSE on :8765
```

## Register with Claude Code

Add to `~/.claude/mcp.json` or project `.claude/settings.local.json`:

```json
{
  "mcpServers": {
    "team-alpha": {
      "command": "team-alpha-mcp",
      "args": [],
      "env": {
        "TEAM_ALPHA_ROLE": "lin",
        "TEAM_ALPHA_NATS_URL": "nats://nats.team-alpha.corp:4222",
        "TEAM_ALPHA_CREDS": "/Users/you/.team-alpha/lin.password"
      }
    }
  }
}
```

Tools become callable as `mcp__team_alpha__<tool>` from the agent session.

## Tools

| group | tools |
|---|---|
| tasks | `claim_task`, `block_task`, `complete_task`, `progress_task`, `post_task` |
| preemption | `park_task`, `resume_task` |
| learning | `claim_learning`, `offer_mentoring`, `post_learning` |
| comms | `dm`, `broadcast_standup`, `broadcast_incident`, `broadcast_announcement` |
| state | `set_load`, `set_human`, `set_policy`, `read_team_state` |
| replay | `recent_events` |

Per-role ACL is enforced client-side: e.g. Sam calling
`claim_task("python", ...)` returns `{ok: false, error: "..."}` immediately
with no NATS roundtrip. Server-side ACL remains the source of truth.

## Tool → subject map (debugging)

When something goes wrong, this table tells you which raw subject to
inspect with `nats stream view AUDIT --subject <subject>`:

| tool | subject(s) published |
|---|---|
| `claim_task(d, s)`        | `board.tasks.<d>.claimed` |
| `block_task(d, s, r)`     | `board.tasks.<d>.blocked` |
| `complete_task(d, s, sha)`| `board.tasks.<d>.done` + `board.results.<d>.shipped` |
| `progress_task(d, s, n)`  | `board.tasks.<d>.progress` |
| `post_task(d, s, ...)`    | `board.tasks.<d>.pending` |
| `park_task(s, b, r)`      | `state.agent.<role>.parked` |
| `resume_task()`           | `state.agent.<role>.resumed` |
| `claim_learning(d, s)`    | `board.learning.<d>.claimed` |
| `offer_mentoring(d,h,t)`  | `board.learning.<d>.mentoring` |
| `post_learning(d, s, ...)`| `board.learning.<d>.pending` |
| `dm(peer, ...)`           | `agents.<peer>.inbox` |
| `broadcast_standup(...)`  | `broadcast.standup` |
| `broadcast_incident(...)` | `broadcast.incidents` |
| `set_load(...)`           | KV `agent.<role>.load` (no event) |
| `set_human(...)`          | KV + `state.agent.<role>.human` |
| `set_policy(...)`         | KV + `state.policy.<name>` |
| `recent_events(s, ...)`   | (read-only) — pull-consumer on AUDIT, filter `s` |

## Test

```bash
python -m pytest tests/                    # unit tests on acl.py (no NATS)
TEAM_ALPHA_ROLE=lin TEAM_ALPHA_NATS_URL=... TEAM_ALPHA_CREDS=... \
  python -m pytest tests/test_smoke.py     # against running substrate
```

## Foot-guns this server hides

See [team-alpha-mcp-server card](../.tasks/team-alpha-mcp-server.md)
for the full list. Short version:

- `nats sub --timeout` (silently ignored) → server uses `--wait`
- `--deliver=all` on AUDIT → server uses bounded `since` window
- consumer name collisions, leaked consumers, AUDIT mirror lag
- payload field drift (`by` vs `role` vs `from`) → canonical `by`
- KV request/reply needs `allow_responses: true` in ACL → server honors

The agent calls typed tools; the server handles the rest.
