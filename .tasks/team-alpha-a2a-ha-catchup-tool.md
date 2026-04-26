---
column: Backlog
created: 2026-04-26
order: 162
---

# A2A catch-up tool — agent_catchup

Agent reconnects after offline window. Without a catchup tool, it
must hand-roll multiple `recent_events` calls + KV reads to know
what happened. Centralize that into one MCP tool.

## Deliverables

### 1. New MCP tool

```python
agent_catchup(
    since: str = "1h",         # 60s, 5m, 1h, 24h, ISO timestamp
    max_count: int = 200,
    mode: str = "summary",     # summary | raw
    include: list[str] | None = None,  # subset of channels
) -> dict:
    return {
        "since": resolved_iso_timestamp,
        "now": iso,
        "channels": {
            "a2a_status":   [...],   # a2a.<role>.tasks.*.status
            "a2a_message":  [...],   # collapsed in summary mode
            "inbox":        [...],   # agents.<role>.inbox DMs
            "broadcasts":   [...],   # broadcast.>
            "alerts":       [...],   # state.alert.>
            "discovery":    [...],   # latest agents/<peer>.json snapshot
        },
        "kv": {
            "load":     {...},
            "human":    {...},
            "parked":   [...],
            "inflight": {...},
        },
        "truncated": false,
        "next_since": iso,
    }
```

### 2. Module: `team_alpha_mcp/a2a/catchup.py`

- per-channel pull from AUDIT (reuses `client.recent_events`)
- summary-mode collapse:
  - `a2a_message`: keep first + last + count per task_id;
    drop intermediate
  - `a2a_status`: keep all (state transitions are rare + meaningful)
  - `inbox`: keep all (rare + meaningful)
  - `broadcasts`: keep last per kind
  - `alerts`: keep all (rare + critical)
- discovery: read latest from A2A_DISC (max-msgs-per-subject 1)
- KV reads: load + human + parked + inflight
- ordering: chronological by event ts (NOT AUDIT arrival), with
  doc note about cross-stream lag (issue #5 in the umbrella card —
  documented in card 166)

### 3. Pagination

`max_count` caps each channel; if hit, set `truncated=true` and
provide `next_since` for the caller to chain.

### 4. Smoke 28

`scripts/smoke/28-a2a-catchup.sh`:
- inject mixed events (status, inbox DM, broadcast, alert) at
  varying ts
- `agent_catchup(role="priya", since="10m")` returns expected channels
- assert summary mode collapses message chunks correctly
- assert truncation kicks in with low max_count

### 5. Sim 13

`scripts/sim/scenario-13-rejoin.sh`:
- priya online; events flow
- kill priya subprocess for 30s; events keep flowing
- restart priya; first thing she does is `agent_catchup(since="2m")`
- assert returned bundle matches what the running observer saw

### 6. Agent prompt update

`scripts/agent-prompts/<role>.md` — add a "On reconnect, call
`agent_catchup(since=last_seen_or_60s)` first" bullet.

## Acceptance

- [ ] `agent_catchup` MCP tool registered, both modes work.
- [ ] Smoke 28 + sim 13 green.
- [ ] Prompts updated.
- [ ] Truncation + chaining tested.

## Refs

- `team-alpha-a2a-ha-resilience.md` — umbrella.
- `team-alpha-a2a-ha-queue-groups.md` (161) — needed first so
  catchup KV reads see post-CAS data.
