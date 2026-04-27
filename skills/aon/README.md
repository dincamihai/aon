# aon-flavored Claude Code skills

Trigger-driven procedures that compress the README §1–§2.5 runbooks
so the next operator/joiner doesn't replay known friction.

## Install

`aon join` symlinks this directory into `~/.claude/skills/aon/`
automatically on every joiner box. To install standalone:

```bash
aon skills install
```

Idempotent. Re-running prints "already linked" and exits 0.

## Skill catalog

### Admin (operator)

| Skill | Use when |
|---|---|
| `aon:add-role` | Adding a role / onboarding a joiner / starting a trial test. |
| `aon:rotate-tunnel` | Cloudflared trycloudflare URL changed; joiners suddenly fail handshake. |
| `aon:diagnose-handshake` | `aon join` fails with "NATS handshake failed" or "Authorization Violation". |
| `aon:trial-test` | Full mid-cycle joiner runbook end-to-end. |
| `aon:settings-recovery` | Joiner's `.claude/settings.json` has stale operator-path hooks. |

### Joiner

| Skill | Use when |
|---|---|
| `aon:join` | First-time joiner walkthrough. |
| `aon:first-turn` | What to do once `claude` boots inside the wired work-repo. |
| `aon:monitor` | Tailing a role's NATS traffic for live observability. |

## Format

Each `*.md` file:

```markdown
---
description: <when to trigger — first sentence is what the model matches on>
---

# <Skill Name>

<imperative procedure>
```

`/skill-creator` (built-in) is the recommended way to add new
skills; it tunes descriptions for triggering accuracy.

## Updating

Skills live in `<engine>/skills/aon/`. Edit + commit + push to the
engine repo. Joiners re-pull engine + skills auto-update via the
symlink.
