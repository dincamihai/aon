---
column: Backlog
created: 2026-04-27
order: 231
priority: low
status_note: postponed-2026-04-27
parent: team-alpha-sandbox-arm-colima-apparmor
depends_on: team-alpha-sandbox-arm-colima-apparmor
runtime: Linux + AppArmor + Claude Agent SDK
---

> **Postponed (2026-04-27):** revisit after Cards 224/228/229/230
> prove out in real use. New service + new profile + Claude Agent
> SDK app + audit pipeline = ~1-2 day slice. Possible MVP split:
> stage 1 = audit→jsonl+NATS pipe, no model, no actions; stage 2
> = add SDK model + bounded toolset (propose_rule, throttle,
> freeze, file_card).

# Card 231 — AppArmor guardian: Claude SDK agent watching kernel audit events

Port from `~/Repos/ai-fleet-harness/.tasks/apparmor-guardian-sdk.md`.

Long-running Claude Agent SDK process inside the sandbox VM that
tails AppArmor audit events in real time and **acts** on them:
classify, escalate, suppress, propose profile diffs, freeze a
worker, file a card. Not in syscall path (no latency); reacts
post-hoc to deny events and patterns.

Complements:
- Static profile = silent floor (Card 224).
- seccomp-notify supervisor = synchronous prompts on a narrow zone (Card 232).
- **Guardian = asynchronous brain** that watches the firehose,
  learns, and proposes changes.

## Why a Claude SDK agent and not a script

- **Intent classification** of denies — "maya tried `curl
  https://x.invalid`, looks like exfil retry; throttle." vs "ok,
  missing `git lfs` binary, propose adding `ix` rule."
- **Cross-event correlation** — N denies on different paths inside
  one card timebox = compromised worker, freeze.
- **Profile diff drafting** — read current profile, propose minimal
  rule additions as a card/PR comment with rationale.
- **Coord-shaped output** — emits cards on the substrate bus
  instead of paging humans.

## Deliverables

- `worker-agent/sandbox/guardian/` — Claude Agent SDK app.
- systemd unit `team-alpha-guardian.service` running as
  `fleet-guardian` UID, separate from coord/workers.
- Audit pipeline: `audisp-syslog` plugin or `auditd` socket →
  guardian stdin. Filters `apparmor=("DENIED"|"ALLOWED" type=AVC)`.
- Per-worker, per-card sliding window state (30 min default).
- Bounded toolset: `propose_rule`, `throttle_worker`, `freeze_worker`,
  `file_card`, `page_coord`. No raw shell.
- `events/guardian-log.jsonl` + NATS `evt.coord-in.guardian`
  publishing on every non-trivial action.

## Acceptance

- Synthetic deny burst on a single worker → guardian freezes that
  worker via NATS event, logs rationale.
- Single deny on a missing-binary path → guardian proposes a rule
  via card on the board, doesn't take action.
- Idle guardian: <50 MB RSS, no CPU spikes.

## Non-goals

- Not a kernel module. Not in syscall path. Latency-free by design.
