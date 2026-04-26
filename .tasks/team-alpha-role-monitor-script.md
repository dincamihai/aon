---
column: In Progress
created: 2026-04-26
order: 211
---

# Card 211 — `role-monitor.sh` multiplexed Monitor + onboard prompt update

## Why

Card 210's onboard brief asks the agent to invoke the Monitor tool
N times, one per subject — works but burdens the agent (3-5 tool
calls before any real work). `nats sub` comma-list parsing is
unreliable across CLI versions (some split, some treat as one
literal subject), so a single multi-subject Monitor isn't
reliable either.

A wrapper script that spawns N parallel `nats sub` processes and
multiplexes their output via `[<subject>]` line prefixes lets the
agent invoke Monitor exactly ONCE per session — same realtime
coverage, lower cognitive load.

## Spec

`scripts/hooks/role-monitor.sh` — already drafted.

- Resolve role from `$TEAM_ALPHA_ROLE` env, then `${PWD##*/}` fallback,
  finally `$1` (CLI override). Uses `_lib.sh` helpers.
- Subject set per role (matches onboard hook's case statement):
  - **maya**: `a2a.>`, `agents.maya.inbox`, `agents.*.events`,
    `broadcast.>`, `state.alert.>`
  - **workers** (raj/lin/sam/diego/priya): `a2a.<role>.tasks.>`,
    `agents.<role>.inbox`, `broadcast.>`
- For each subject, spawn `nats sub <subj>` in a subshell that
  prefixes each delivered line with `[<subj>]` and pipes to stdout.
- Use `set -m` + `trap cleanup TERM INT EXIT` + `kill -TERM 0` so a
  single SIGTERM (Claude Code's TaskStop) tears down the whole
  process group cleanly.
- Use `stdbuf -oL` on each `nats sub` to keep output line-buffered
  through the pipe (otherwise pipe buffering delays events).

## Onboard prompt changes

Currently `session-start-onboard.sh` emits one Monitor block per
subject (3-5 blocks). Replace with a single block:

```
ACTION REQUIRED — invoke the Monitor tool ONCE with these EXACT
parameters. This is your realtime event stream covering every
subject your role needs. Without it you receive no notifications
and fall back to polling (anti-pattern).

  description: "team-alpha <role> realtime"
  command: bash /Users/mid/Repos/ai-over-nats/scripts/hooks/role-monitor.sh
  persistent: true
  timeout_ms: 3600000

Each event arrives as a notification prefixed with `[<subject>]`,
so you can tell at a glance which channel fired:
  - `[a2a.<role>.tasks.<id>.send]`  new A2A task dispatched to you
  - `[agents.<role>.inbox]`         peer DM
  - `[broadcast.>]`                 incident / standup
  - (maya only) `[agents.*.events]` peer presence / handshake
```

Same priya/maya routing rules ("call `a2a_inbox()` once on new task
notification, etc.") follow the block.

## Files

- `scripts/hooks/role-monitor.sh` — drafted, needs verification
- `scripts/hooks/session-start-onboard.sh` — collapse N blocks → 1
- `.tasks/team-alpha-role-monitor-script.md` — this card

## Acceptance

- [ ] `bash role-monitor.sh` from `~/team-alpha/<role>/` opens N
      subscriptions, one per role-relevant subject. Verify via
      `connz?subs=detail` — expect `subs=N+1` (N + _INBOX).
- [ ] Sending `nats pub` on any role subject produces a prefixed
      `[<subj>] <payload>` line on stdout within 200ms.
- [ ] SIGTERM (or Claude Code TaskStop) tears down all child
      `nats sub` processes — verify with `ps aux | grep nats sub`
      = 0 after stop.
- [ ] Onboard hook emits exactly ONE Monitor block.
- [ ] Cold maya / priya session, after `/clear`, runs Monitor
      once and gets full coverage.
- [ ] Defect 208 stays fixed (single-instance per role, single
      delivery).

## Out of scope

- Auto-restart on `nats sub` crash (could add later via `while true; do nats sub ...; done`).
- Subject de-dup if user provides overlapping patterns.
- Per-event filtering / kind tagging — keep it raw, agent decides.

## Refs

- Card 210 — Phase A.5 introduced the Monitor priming pattern.
- Card 60 — `_lib.sh` provides the role + creds resolution.
- Membrain `~/Repos/membrain/hooks/session_start.sh` — original
  inspiration.
