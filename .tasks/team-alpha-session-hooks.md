---
column: Backlog
created: 2026-04-26
order: 210
---

# Card 210 — Session hooks for team-alpha agents (membrain-inspired)

## Relation to card 60 (`team-alpha-hooks.md`)

Card 60 is the foundation — plans `session-start-catch-up.sh`,
`stop.sh`, `user-prompt-submit.sh`, `install.sh`, with a shared
`_lib.sh` (publish_event, publish_to_inbox, etc.). Marked Done but
scripts never wired into `~/team-alpha/<role>/.claude/settings.json`
— gap surfaced during T1 live retest.

Card 210 = card 60 + post-membrain lessons:

| Phase | Source                       |
|-------|------------------------------|
| A     | extends card 60 catch-up     |
| **A.5** | **NEW — Monitor priming** (membrain killer pattern) |
| **B** | **NEW — idle drill** (post-completion)              |
| **C** | **NEW — recap_request round-trip** (post-compact)   |
| D     | extends card 60 stop.sh      |

Reuse `_lib.sh` from card 60. Don't reinvent helpers.

## Why

Live Claude sessions launched in `~/team-alpha/<role>/` have no role
identity beyond a dormant CLAUDE.md symlink. T1 retest (defect 205
follow-up) showed maya still asked operator for VPC IDs / module
paths after `/clear` because role context wasn't reinforced and live
state (inflight tasks, broadcasts, inbox DMs) wasn't surfaced.

Membrain (`~/Repos/membrain/hooks/`) solves the analogous problem
with a hook suite that is dynamic, concise, and actionable. We
adapt the pattern, not the content.

## Inspiration: membrain hook suite

| Hook                     | Membrain purpose                                  | Team-alpha analog                                            |
|--------------------------|---------------------------------------------------|--------------------------------------------------------------|
| `session_start.sh`       | `membrain ask` synthesizes briefing from memory   | `nats kv get` + `recent_events` synthesizes role brief       |
| `post_compact_recap_request.sh` | NATS publish `evt.coord-in.recap_request` post-compact | NATS publish `agents.<role>.events {kind:"recap_request"}` post-compact |
| `post_pr_idle_drill.sh`  | After PR ship, idle reminder via system-reminder  | After `.status=completed` emit, idle reminder ("watch a2a_inbox") |
| `post_tool_pr_marker.sh` | Drop file marker on `gh pr create` for Stop hook  | Drop marker on `a2a_update_status(state="completed")` so Stop hook idles cleanly |
| `pre_compact.sh`         | Store compact summary in membrain                 | Publish `agents.<role>.events {kind:"compact_summary", summary}` to AUDIT |
| `session_end_goodbye.sh` | Publish goodbye on NATS to peers                  | Publish `state.agent.<role>.human {status:"away"}` + `agents.<role>.events {kind:"goodbye"}` |
| `stop.sh`                | Enqueue transcript ingest                         | (Optional) Audit summary append; lower priority              |
| `user_prompt.sh`         | Passive (per ADRs)                                | Passive (no per-prompt context inject; SessionStart enough)  |

## Concrete plan

### Phase A — SessionStart brief (highest value)

`scripts/agent-prompts/hooks/session_start.sh`:

1. Derive role from `${PWD##*/}` (matches `~/team-alpha/<role>/` convention).
2. Read role brief from `scripts/agent-prompts/<role>.md` (first 80 lines).
3. Query live state via `nats` CLI w/ sysadmin creds:
   - `kv get team-state a2a.<role>.inflight` → count + first 3 task summaries
   - `kv get team-state agent.<role>.parked` → parked work
   - `recent_events broadcast.> --since=1h` → active broadcasts
   - `recent_events agents.<role>.inbox --since=10m` → unread DMs
4. Emit JSON `{hookSpecificOutput: {hookEventName: "SessionStart",
   additionalContext: "<brief>"}}` to stdout.
5. Bound output ≤ 60 lines / 4KB.

Brief template:

```
You are **<role>** in team-alpha (<one-line specialty>).

## Live state
- Inbox: N A2A tasks awaiting via `a2a_inbox()`. First: <task_id> <skill> from <peer>.
- Parked: <count or 0>.
- Broadcasts (1h): <count, severities>.
- Inbox DMs (10m): <count or 0>.

## Key A2A tools
- a2a_inbox()                              — your work surface
- a2a_update_status(task_id, state, ...)   — report progress / complete
- a2a_emit_message(task_id, "need <X>")    — async clarify with sender
- a2a_send_task(skill, payload) (maya only) — dispatch to peer

## Role brief
<first 80 lines of scripts/agent-prompts/<role>.md>
```

### Phase A.5 — Monitor priming (the realtime substrate)

Membrain's killer move: SessionStart hook prints **the exact Monitor
tool invocation** the agent must run first turn, with literal
`description / command / persistent / timeout_ms` parameters. That
makes the first turn deterministic and gives the agent a live event
stream — no polling, no `recent_events` loops.

Team-alpha equivalent: each role's brief ends with an "ACTION
REQUIRED" block:

```
ACTION REQUIRED — invoke the Monitor tool now to subscribe to your
A2A event stream. Use these EXACT parameters:

  description: "team-alpha priya inbox + status"
  command: "nats --server nats://localhost:4222 --user sysadmin --password devpass sub 'a2a.priya.tasks.>,agents.priya.inbox' 2>&1"
  persistent: true
  timeout_ms: 3600000

Each new event becomes a notification mid-session — you do NOT need
to poll `a2a_inbox()` repeatedly. Acknowledge new task notifications
by calling `a2a_inbox()` once, then `a2a_update_status` when done.
```

Subjects per role:
- maya: `a2a.>,agents.maya.inbox,broadcast.>` (manager wants
  everything visible)
- workers: `a2a.<role>.tasks.>,agents.<role>.inbox,broadcast.>`

This is THE pattern that breaks the polling trap from defect 207.
Monitor delivers per-message notifications via stdout — agent reacts
event-driven instead of "next poll in 10min."

### Phase B — Idle drill (after task completed)

`scripts/agent-prompts/hooks/post_complete_idle_drill.sh`
(Stop or PostToolUse depending on Claude Code event semantics):

After `a2a_update_status(state="completed")`, emit system-reminder:

```
Task complete. You are idle. Do NOT scan for new work via prompts —
your accept loop handles new dispatches in the background. Wait for
the operator or use Monitor on `a2a_inbox()` if you want to be
woken on new tasks.
```

This breaks the "next 10min poll" trap from defect 207 by signaling
event-driven over polling.

### Phase C — Pre-compact recap

`scripts/agent-prompts/hooks/pre_compact.sh`:

Publish `agents.<role>.events {kind:"compact", summary:<short>,
ts}` to NATS so peers / observers know context window compacted
(state may be lossy after).

### Phase D — Session-end goodbye

`scripts/agent-prompts/hooks/session_end.sh`:

- Publish `state.agent.<role>.human {status:"away", since:<ts>}`
  to KV so dispatcher won't pick this role for new work.
- Publish `agents.<role>.events {kind:"goodbye"}` for AUDIT.

## Wiring

Per-role `~/team-alpha/<role>/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command",
      "command": "bash /Users/mid/Repos/ai-over-nats/scripts/agent-prompts/hooks/session_start.sh"}]}],
    "PreCompact": [{"hooks": [{"type": "command",
      "command": "bash /Users/mid/Repos/ai-over-nats/scripts/agent-prompts/hooks/pre_compact.sh"}]}],
    "SessionEnd": [{"hooks": [{"type": "command",
      "command": "bash /Users/mid/Repos/ai-over-nats/scripts/agent-prompts/hooks/session_end.sh"}]}]
  }
}
```

Add `scripts/agent-prompts/hooks/install.sh` to write these into
each `~/team-alpha/<role>/.claude/settings.json` for the 6 roles.

## Acceptance

- [ ] Cold maya session in `~/team-alpha/maya/` shows role brief +
      live state via SessionStart hook.
- [ ] Cold priya session ditto, with inbox count > 0 if dispatch
      pending.
- [ ] Maya, given "Dispatch a terraform task: add staging VPC peering",
      calls `a2a_send_task` within first turn without operator priming.
- [ ] Priya, given "Check inbox," calls `a2a_inbox()` first turn.
- [ ] Compact event triggers `agents.<role>.events.kind=compact` in AUDIT.
- [ ] Session end triggers `state.agent.<role>.human.status=away` in KV.
- [ ] Brief stays ≤ 4KB; cold start adds ≤ 1.5s.
- [ ] Cold session's first turn invokes the Monitor tool with the
      exact params from the brief — no operator nudging.
- [ ] New A2A dispatch arrives as a notification mid-session via
      Monitor stdout, not via polling.

## Out of scope

- Multi-line / persistent context injection per user prompt
  (membrain ADR-005/008: pull model, not push).
- Cross-role broadcasts on session start (separate concern).
- Replacement of CLAUDE.md symlink — keep both; symlink is
  fallback when hook fails or NATS down.

## Refs

- `~/Repos/membrain/hooks/session_start.sh` — synthesis pattern.
- `~/Repos/membrain/hooks/post_pr_idle_drill.sh` — idle drill pattern.
- `~/Repos/membrain/hooks/install.sh` — settings registration.
- Defect 205, 206, 207 — UX gaps this card addresses at the harness layer.
- `team-alpha-hooks.md` — earlier hooks card (check overlap).

## Appendix: lessons from membrain transcripts

Sources (all under `~/.claude/projects/-Users-mid-Repos-membrain/`):
`ebaea466-c79a-4fbc-8150-ee3cd1678bee.jsonl` (4.8MB coord, 26 Apr),
`d82a3dd2-d89c-4aac-a486-ec2f74e70b05.jsonl` (2.9MB coord, 25 Apr),
`499189e1-c9bb-4f7d-bf10-a5d49479cbdf.jsonl`, `0d111520-...jsonl`.

### 1. Session bootstrap — what actually fires

- Two SessionStart hooks chain: `hooks/session_start.sh` (membrain-ask
  briefing, low signal — usually returns "No relevant memories found") and
  the louder `scripts/hooks/session-start-onboard.sh` which is the real
  workhorse [ebaea466 line 4]. The latter does: (a) `git pull --rebase
  --autostash`, (b) publishes `handshake` on `evt.{peer}-in.handshake`,
  (c) injects `additionalContext` containing role, identity, sync result,
  handshake status, **and a literal "ACTION REQUIRED: invoke the Monitor
  tool now"** with exact `description/command/persistent/timeout_ms`
  parameters spelled out.
- **Agent's first turn is deterministic**: open the Monitor with those
  exact params, then ask the operator which resume prompt to pick
  [ebaea466:20-28, d82a3dd2:21-28]. The instruction-with-exact-params
  pattern is what makes it deterministic — earlier transcripts
  (499189e1) where the script only said "start the monitor" required
  operator nudging ("check the start session script, it is supposed to
  instruct you to start the monitor as coordinator").
- Role is derived from env (`MEMBRAIN_BOX_ROLE` + `MEMBRAIN_WORKER_ID`),
  not from `${PWD##*/}` as the card currently plans. `WORKER_ID`
  dominates `BOX_ROLE`. Worth copying.

### 2. Steering pattern — coord -> worker

Steering events are large free-form `message` fields published on
`evt.worker-in.steering` [d82a3dd2:189, 200, 308]. Format that works:

- Heredoc the message into `/tmp/steer-msg.txt`, then
  `jq -nc --rawfile msg ...` into the event (avoids escaping hell on
  long technical content).
- Effective steering messages are: concrete API names, code sketch,
  exact crate/version, pasted reference values, and a closing
  `ASK if X` line that reasserts the ask-don't-guess rule.
- Steering can also be a **correction** ("ignore prior steering" — line
  200), or an **identity check** ("You are gigi... evo is a separate
  worker on this same box... do NOT touch that branch" — line 308).
  Identity-check steering exists *because* multi-worker on one box
  caused branch confusion.

### 3. Idle pattern — post-PR

`post_tool_pr_marker.sh` (PostToolUse) drops a JSON marker file when
`gh pr create` runs; `post_pr_idle_drill.sh` (Stop) reads the marker
and emits a `[POST-PR IDLE DRILL — automatic system reminder]`
including the four-step shutdown drill: confirm OPEN, publish
`pr_opened`, run `worktree-cleanup.sh`, **"Stop. Do NOT scan for the
next card. Idle on your Monitor until the coord pushes a new_card
event. Workers do not pull; coord assigns."** [hooks/post_pr_idle_drill.sh].
The card explicitly says hooks cannot invoke `/clear`, so this drill
is the *approximation* of clearing context [d82a3dd2:928 — the card
that designed it].

### 4. Failure / friction modes

- **Stale tunnel URL** [ebaea466:31-55]: cloudflared rotated host;
  Monitor failed; agent correctly diagnosed but operator still had to
  paste the new hostname. Lesson: env discovery should be programmatic,
  not per-session-startup. (Membrain workaround is `events/nats-url.txt`
  in the repo, refreshed by `cf-tunnel-publish.sh` on the worker box.)
- **Identity confusion across workers on one box**: required a
  defensive identity-check steering [d82a3dd2:308]. Multi-worker
  collisions are a real failure mode.
- **Pull-vs-push drift**: workers occasionally tried to "do more" on a
  shipped card; the post-PR idle drill was created specifically to fix
  this [d82a3dd2:928 card text].
- **Operator interruptions**: `[Request interrupted by user]` appears
  ~11 times in ebaea466 — coord agent went off on tangents
  (architecture musings, protocol comparisons) when it should have
  stayed reactive. Lesson: a passive coord that *only* acts on events
  + operator prompts beats a chatty one.
- **Compaction loses context**: solved by `post_compact_recap_request.sh`
  → publishes `recap_request` to coord on SessionStart with
  `source=compact`; coord replies on `evt.worker-in.steering` with
  `[POST-COMPACT RECAP]` prefix containing current claim, recent
  steerings, follow-ups, process rules. Round-trip recap, not
  client-side replay.

### 5. Copy vs skip for team-alpha

**Copy:**
- The "ACTION REQUIRED + exact tool params" SessionStart pattern. Don't
  describe what to do — print the exact tool call shape. This is what
  makes maya/priya call `a2a_inbox()` first turn.
- Two-hook layering: a quiet briefing hook (`a2a_inbox`-style state)
  + a loud "do this now" onboard hook. Keep them separate so the
  briefing can fail silently without breaking onboarding.
- PostToolUse marker -> Stop drill split for idle. PostToolUse can't
  inject context (stdout leaks); Stop can. The marker file bridges
  them.
- Heredoc-to-tmpfile pattern for any long message (steering, recap)
  published over NATS — saves you from JSON-in-shell escaping.
- `recap_request` round-trip on post-compact SessionStart — much
  better than trying to stuff a summary into a single context inject.
- Identity / role envvars (`MEMBRAIN_BOX_ROLE`, `MEMBRAIN_WORKER_ID`)
  override `${PWD##*/}` derivation. Worktree dirs change; env doesn't.

**Skip / membrain-specific:**
- `membrain ask` LLM-synthesized briefing — it returned "No relevant
  memories found" in every transcript checked. Direct KV reads are
  cheaper and more reliable for live state.
- Debug-triplet extraction in `stop.sh` — that's domain-specific
  knowledge mining, not session hooks.
- Cloudflared tunnel + `events/nats-url.txt` — team-alpha is on a
  static NATS endpoint, no tunnel rotation problem.
- Worker-pulls-card vs coord-assigns is a membrain process choice;
  team-alpha A2A is dispatch-driven by design — same outcome,
  different mechanism. The *idle drill text* still applies, just swap
  "new_card event" for "a2a_inbox()".
- `transcript_summary` ingest queue (`stop.sh`) — long-term memory
  isn't in scope for the session-hooks card.
