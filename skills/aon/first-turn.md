---
description: First-turn discipline for an aon role agent — what to do the moment claude boots inside a wired work-repo. Suppresses the global resume-prompt block, opens the Monitor on the role's subjects, calls a2a_inbox, then waits for instruction. Use when the user says they just joined, just booted claude as a role, are doing first-turn as <role>, or asks "what do I do first". Trigger phrases include "first turn", "I just joined", "onboard me as <role>", "claude just started as <role>", "what do I do first", "boot as <role>".
---

# aon: first-turn discipline (for the agent)

You are running inside a work-repo with `<work-repo>/.mcp.json` and
`<work-repo>/.claude/settings.json` already stamped by `aon join`.
Your role is `$TEAM_ALPHA_ROLE`. This is your first turn in this
session.

## Suppress the global resume-prompt hijack (defect 216)

If you see a system reminder titled
`== Pending resume prompts (auto-loaded) ==`, **ignore it**. Those
are the operator's personal cross-session notes. They have nothing
to do with your role.

- Do NOT ask the user "which resume prompt should I continue?"
- Do NOT pick one.
- Do NOT mention them.

Just skip the block silently.

## Step 1 — Open the Monitor on your subjects

The SessionStart `onboard` hook just told you exactly which
subjects to subscribe to (look at the system message it injected).
Invoke the **Monitor** tool with that subject list.

Pattern:

```
description: "<team> <role> realtime"
command: bash -l -c "aon monitor <role>"
persistent: true
timeout_ms: 3600000
```

Keep it open in the background for the entire session. The
`bash -l` is required — child shells don't inherit hook env.

## Step 2 — Call `a2a_inbox()`

Pick up any tasks dispatched to you while you were offline.

```
mcp__team-alpha__a2a_inbox()
```

Returns dispatched tasks (status `submitted` or `working`). For
each: read the description, decide if it's still relevant (some
may be stale), and either accept (`a2a_update_status` →
`working`), defer (`parked`), or decline (`canceled` with reason
in the message).

## Step 3 — Read your role brief

Already symlinked at `<work-repo>/CLAUDE.md` → your role's brief
in `agent-prompts/<role>.md`. Read once if you don't remember the
team rules. Re-read on `[ROLE BRIEF REFRESH]` reminders later.

Also skim `agent-prompts/_common.md` for substrate / identity /
ASK discipline / preempt protocol.

## Step 4 — Check policy + human availability

```
mcp__team-alpha__kv_get(key="policy.delegated")
mcp__team-alpha__kv_get(key="agent.<role>.human")
```

- `policy.delegated = false` → human-in-loop required for
  non-trivial actions. Ask before shipping.
- `agent.<role>.human = available` → normal HITL.
- `agent.<role>.human = busy / offline` → defer non-urgent;
  queue ASKs, don't flood.
- `agent.<role>.human = delegated` → autonomous within `scope`,
  until `until`.

## Step 5 — Wait

Wait for **either**:

- An operator instruction in chat.
- A dispatch event from Monitor (`agents.<role>.inbox` or board
  `pending`).

Do **not** start claiming work proactively until either signal. The
operator may have a specific task in mind; jumping in early creates
preemption.

## Status discipline

After every substantive tool call, the `post-tool-status-ping`
hook publishes a status event for you. You don't need to do it
manually. But:

- DO keep `a2a_update_status` calls accurate (`working` /
  `parked` / `blocked` / `completed` / `canceled`).
- DO DM the dispatcher proactively when blocked mid-task:
  `dm(peer="maya", type="blocked", message="...")`.
- DO NOT manually publish to `agents.<role>.events` to mimic the
  hook — duplicate emits.

## ASK / retry discipline

When stuck:

1. DM peer specialist ONCE (`agents.<peer>.inbox`).
2. If no reply in ~10 min, DM coordinator ONCE
   (`agents.maya.inbox`).
3. If still stuck and human is busy/offline, publish
   `state.alert.no_human` ONCE.
4. After step 3, **stop working that thread.** Report blocked.
   Do not retry.

Cost of one ask = one event. Cost of guessing wrong = hours of
redo.

## Audit / dual-write

There is no dual-write. You publish once to NATS; AUDIT mirrors
everything. Do not maintain a separate JSONL log or git-commit an
event log. Substrate IS the audit trail.
