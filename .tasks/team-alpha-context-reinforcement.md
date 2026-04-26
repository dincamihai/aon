---
column: Backlog
created: 2026-04-26
order: 212
---

# Card 212 — Context reinforcement: role-prompt re-reads + status pings

## Why

Membrain's hook stack does two things team-alpha currently lacks:

1. **Periodic role-prompt re-reads** after specific tool executions —
   keeps the role rules fresh in the model's working context as the
   conversation grows.
2. **"Tell coord what you're doing" reminders** — every N turns or
   after a notable action (PR open, branch switch), worker emits a
   status event so coord/dispatcher (and any human observer) knows
   what the worker is up to without asking.

Without these, two failure modes appear in long sessions:

- The role brief gets paged out of attention; agent drifts back to
  generic Claude defaults (over-cautious, conversational, polling
  loops).
- Coord / operator must constantly ask "where are you?" because
  worker is silent until done.

T1 retest already showed both: maya greeted instead of dispatching
(role brief drifted), priya never told maya "I started, blocked on
spec" without operator nudging.

## Membrain references

- `~/Repos/membrain/hooks/post_tool_use.sh` — currently no-op per
  ADR-005, but the *slot* exists; older versions injected reminders.
- `~/Repos/membrain/hooks/post_tool_pr_marker.sh` + `post_pr_idle_drill.sh`
  — example of "after big tool action, inject a reminder via Stop hook."
  Pattern: PostToolUse drops marker → Stop reads marker → emits
  system-reminder text.
- Membrain coord agent's transcript shows worker periodically publishing
  `evt.coord-in.status` with `{kind:"working", task, eta}` — keeps
  coord aware. Triggered by post-tool reminders ("tell coord you've
  started").

## Spec

### Phase A — Periodic role-prompt re-read

`scripts/hooks/post-tool-context-refresh.sh`

- PostToolUse hook. Stdout doesn't reach model directly — drop a
  marker file `~/.team-alpha/refresh-role-<role>.marker` at most
  once every 30 minutes (rate-limited by mtime).
- Trigger conditions (any one):
  - Tool count since last refresh > 25
  - Tool name in {`Edit`, `Write`, `Bash`} after a 10+ tool gap
  - `a2a_send_task`, `a2a_update_status`, or `dm` ran (high-stakes
    A2A actions worth re-reading rules for)

Stop hook reads marker → emits system reminder:

```
[ROLE BRIEF REFRESH — automatic system reminder]

You've been working for a while. Re-anchor on your role:

- Read your CLAUDE.md (auto-loaded earlier — re-skim).
- For full rules, scripts/agent-prompts/<role>.md.
- Remember: <one-line role identity>.

Resume current work after the re-anchor.
```

### Phase B — Status pings to coord/dispatcher

`scripts/hooks/post-tool-status-ping.sh`

PostToolUse hook. After a *substantive* tool action (not every
trivial Read), publish a status event so the dispatcher (maya for
worker roles, no-op for maya herself) knows what's happening.

Trigger conditions:
- `a2a_update_status` ran (forward the new state to maya's inbox
  too, not just the canonical AUDIT subject).
- `Edit` / `Write` ran on a file in `~/Repos/<repo>/` AND we have
  a current task_id in `a2a.<role>.inflight` KV → publish
  `agents.<role>.events {kind:"working", task_id, file:<path>,
  ts}`.
- `a2a_send_task` ran (maya only) — publish
  `agents.maya.events {kind:"dispatched", target, skill, task_id, ts}`.
- 30+ min idle, then any tool — publish `kind:"resumed"`.

Rate-limit: max 1 status ping per minute per kind to avoid AUDIT
spam.

Maya's Monitor subscribes to `agents.*.events` so she sees these
in realtime; dashboards / observers can replay from EVENTS stream.

### Phase C — Prompt-side scaffolding

Add a section to each role brief:

```
## Status discipline

- After every substantive action (file edit, tool call that
  changes state, A2A status update), the post-tool-ping hook
  publishes a status event for you. You don't need to do it
  manually — but DO keep your `a2a_update_status` calls accurate
  (working / blocked / completed) because the ping rides on those.
- If you need help mid-task, DM the dispatcher proactively via
  `dm(peer="maya", type="blocked", message="...")` — don't wait
  for someone to ask.
```

## Files

- `scripts/hooks/post-tool-context-refresh.sh` — new
- `scripts/hooks/post-tool-status-ping.sh` — new
- `scripts/hooks/stop.sh` — extend marker-handling block for refresh
- `scripts/hooks/install.sh` — register both PostToolUse hooks
- `scripts/agent-prompts/<role>.md` × 6 — add Status discipline section
- `.tasks/team-alpha-context-reinforcement.md` — this card

## Acceptance

- [ ] After 25 tool calls since session start, refresh reminder fires
      next Stop. Verified by tool counter file.
- [ ] After `a2a_send_task`, `agents.maya.events.kind=dispatched`
      lands in EVENTS stream within 1s.
- [ ] After `a2a_update_status(state=working)`, `agents.<role>.events
      .kind=working` lands.
- [ ] Rate-limit holds: 10 rapid `a2a_update_status` calls produce
      ≤ 1 status ping in EVENTS per minute (defensive de-dup).
- [ ] T1 cold-rerun: maya dispatches, priya emits status pings without
      operator prompting.
- [ ] Refresh reminder text stays under 30 lines, never repeats within
      the same 30-min window.

## Out of scope

- LLM-synthesized status summaries (membrain ADR-008 territory —
  defer to long-running coord agent).
- Multi-event batching — single emit per trigger is fine for now.
- A coord agent that consumes status pings and replies with steering
  — separate card, after team-alpha has multi-role real sessions.

## Refs

- Card 210 — Phase B already establishes the PostToolUse → Stop
  marker pattern (post-tool-use.sh + stop.sh). Reuse it.
- Card 211 — Monitor wrapper, prerequisite for maya to actually
  see the ping events.
- Membrain `post_tool_pr_marker.sh` — pattern source.
- T1 retest 2026-04-26 — empirical motivation.
