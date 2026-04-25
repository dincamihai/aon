---
column: Backlog
created: 2026-04-25
order: 90
---

# Human availability — when human can't drive the agent

Default posture (per card 07-human-in-loop.sh): **human is in the loop unless
explicitly delegated**. But humans are sometimes unavailable: in meetings, on
call for higher priority, or simply asleep. Substrate must:

1. Tell the agent the human is unavailable.
2. Let the agent decide whether to wait, defer, or escalate based on its
   delegation policy.
3. Surface stuck-on-human situations to the rest of the team so a peer can
   step in.

## Premise

- Each role has a KV value `state.agent.<role>.human` indicating human
  status: `available | busy | offline | delegated`.
- Default = `available`. Set by the human (via shell helper) or by hooks
  (e.g. when a calendar plugin says they're in a meeting; out of scope for
  v1 — manual flip is fine).
- The agent reads its own `human` KV before any non-trivial action. If
  `available`, normal HITL flow (ask, wait). If `delegated`, autonomous up
  to delegation scope. If `busy`/`offline`, defer non-time-critical, queue
  ASKs, escalate critical to peer or coordinator.

## Scope

### Conventions

- **Manual flip**: shell helper `bin/team-alpha-status <state>` writes
  KV `state.agent.<role>.human` and emits `state.agent.<role>.human` event
  for live subscribers (Maya is subscribed to `state.>`).
- **Agent reads on every cycle start**: hook
  `session-start-catch-up.sh` or a new `pre-tool-use` hook injects
  `human_status` into `additionalContext`.
- **Delegation scope**: `delegated` carries an optional payload
  `{"scope":"<domains>","until":"<ISO>"}` in KV. Agent honors scope (e.g.
  delegated for terraform tasks only, expires at 17:00 today).
- **Escalation when stuck**: agent posts `agents.<peer>.inbox` w/
  `escalation` + reason (their human unavailable). If no peer responds in N
  minutes, escalates to `agents.maya.inbox` and emits
  `state.alert.no_human` on `state.alert.>`.

### Smoke scripts

- `13-human-unavailable-defer.sh`: flip Lin's `human` to `busy`, post a
  task on `board.tasks.python.pending`, expect Lin's agent to either defer
  (no claim) or claim+stop-before-action. Validates the **substrate** path —
  enforcement of behavior is the prompt's job.
- `14-delegate-scoped.sh`: flip Diego's `human` to
  `delegated:scope=go,until=...`. Post go task → expects claim. Post
  terraform task → expect *not* claim (out of scope).
- `15-stuck-on-human-escalation.sh`: synthesize agent-stuck-waiting on a
  busy human. Trigger escalation timer, assert
  `agents.maya.inbox` receives an escalation event AND
  `state.alert.no_human` is emitted.

### Detection mechanism

- Coordinator-watcher (from card 80) tracks `state.agent.*.human` flips +
  any `state.alert.no_human` events. Maintains live "team availability
  view" — read-only KV `state.team.alpha.availability`. Maya's monitor
  prints it on each session-start hook.

## Files

- `bin/team-alpha-status` — shell tool to flip own status.
- `scripts/smoke/{13,14,15}-*.sh`
- coord-watcher updates
- prompt updates: HITL gate + delegation honor + escalation trigger

## Acceptance

- [ ] Smoke 13/14/15 pass.
- [ ] Flipping Lin to `busy` is reflected in `state.team.alpha.availability`
      within 5s.
- [ ] Delegated scope is honored: out-of-scope claim attempts blocked at
      prompt level (with substrate audit confirming the agent saw scope and
      chose not to claim).
- [ ] Escalation chain (peer → Maya → alert) triggers on synthetic stuck.

## Open questions

- Should human unavailability **block** the agent at the substrate level
  (e.g. revoke `claim` perms when `busy`)? Cleaner but heavy. Default:
  enforce in prompt, audit in substrate, alert when violated. Promote to
  substrate only if prompt-level enforcement proves unreliable.
- Calendar integration for auto-flip — defer until manual flip is shipping.
