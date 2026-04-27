---
description: Quick start for tailing a role's NATS traffic via aon monitor — the operator-or-joiner observability tool. Explains how to launch a monitor pane and what each subject category means. Use when the user wants live visibility on a role, is debugging team coordination, asks to "watch the team", "see what <role> is doing", or "open a monitor". Trigger phrases include "aon monitor", "monitor my role", "watch <role>", "watch the team", "tail NATS", "see live events".
---

# aon: monitor a role

Tail the role's NATS subjects in a live-streaming pane. Reads team
config + creds automatically — no manual env setup.

## Launch

```bash
# explicit role
aon monitor <role>

# default to $TEAM_ALPHA_ROLE if set in env (e.g. inside an aon launch shell)
aon monitor
```

Run one pane per role you want to watch. Common operator setup:

- pane 1: `aon monitor <joiner-role>` — see them connect + work.
- pane 2: `aon monitor maya` (or whichever is your manager) —
  coordination signals, dispatch decisions.
- pane 3: `aon monitor mihai` — your own audit trail, useful when
  debugging your hooks or commands.

## Inside Claude Code

Use the **Monitor** tool with this command pattern:

```
description: "<team> <role> realtime"
command: bash -l -c "aon monitor <role>"
persistent: true
timeout_ms: 3600000
```

`bash -l` is required so login-shell PATH is loaded (child shells
don't inherit hook env). Without it `aon` may not be on PATH.

## What you'll see — subject categories

| Subject prefix | Meaning |
|---|---|
| `agents.<role>.events` | Their outbound events: hello, status, dispatched, working, completed, blocked. |
| `agents.<role>.inbox` | DMs to that role: ASKs, dispatch from coordinator, blocked replies. |
| `board.tasks.<domain>.<state>` | Work-board state transitions. States: pending, claimed, blocked, done, parked, resumed, progress. |
| `board.learning.<domain>.<state>` | Growth-track equivalent (mentoring offers, learner pickups). |
| `board.results.<domain>.>` | Finished work artifacts (PRs, shipped slugs). |
| `broadcast.>` | Team-wide announcements. |
| `state.alert.>` | Coordinator-watcher alerts (no_human, etc.). |
| `AUDIT.>` | (if subscribed) full audit mirror — all messages durably persisted. |

## Useful filters

To grep for one symptom in a noisy pane, use the `nats sub` form
directly:

```bash
PW=$(cat ~/.team-alpha/<role>.password) NATS_PASSWORD="$PW" \
nats --server <wss-url> --user <role> sub 'AUDIT.>' \
  | jq -c 'select(.kind == "blocked" or .kind == "dispatched")'
```

Useful for debugging dispatch races or stuck workers without
reading every event.

## When to expect events

After a joiner runs `claude`:
- ~5–30s: `agents.<role>.events {kind: "hello"}` (onboard hook).
- ~5–30s: first `agents.<role>.events {kind: "status"}`.
- Whenever they call MCP tools that emit status: `working`,
  `dispatched`, `completed`.

Silence beyond 60s after `claude` boots → DM operator to run
`/aon:diagnose-handshake`.

## Multi-pane setup

Tmux example (split-window):

```bash
tmux new-session -d -s team -n monitor 'aon monitor maya'
tmux split-window -t team:monitor -h 'aon monitor vahid'
tmux split-window -t team:monitor -v 'aon monitor mihai'
tmux attach -t team
```
