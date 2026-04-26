---
column: Backlog
created: 2026-04-26
order: 216
---

# Defect 216 — Global resume-prompt SessionStart hook hijacks role-agent first turn

## Symptom

Every team-alpha role session (maya / priya / raj / lin / sam /
diego) begins with the global `~/.claude/hooks/*` SessionStart
output:

```
== Pending resume prompts (auto-loaded) ==
- topic: ...
  path:  ...
  ...
INSTRUCTION FOR CLAUDE: on first turn, ask the user which resume
prompt to continue (or 'none'). ...
== End resume prompts ==
```

Role agents obey the instruction, ask the operator to pick a
resume prompt, and skip their own deterministic first turn (open
Monitor on `a2a.<role>.tasks.send`, call `a2a_inbox`, dispatch).

This breaks Card 210's "first turn is deterministic" property and
contaminates worker context with operator-personal resume topics
(membrain-coord, adr-003, etc.) that have nothing to do with the
team-alpha role.

T1 retest 2026-04-26: maya greeted operator + asked which resume
prompt instead of dispatching.

## Root cause

`~/.claude/hooks/session-start-resume.sh` (or equivalent) is
user-global; it fires for every Claude Code session regardless of
cwd or role. Team-alpha role sessions use the same `claude` binary
and inherit the global hook chain.

## Fix options

### A — Role brief explicit suppression (cheap)

Add to `scripts/agent-prompts/_common.md`:

```
## Resume-prompt suppression

The host Claude install ships a global SessionStart hook that
injects a "Pending resume prompts" block asking you to pick one.
**Ignore that block entirely when running as a team-alpha role.**
Those resume prompts are operator-personal and unrelated to your
role. Your first turn is fixed by Card 210 — open Monitor on
`a2a.<role>.tasks.send`, then call `a2a_inbox()`. Do not ask the
operator about resume prompts.
```

Pro: zero infra change. Con: relies on LLM to obey; not
deterministic.

### B — SessionStart hook gating (proper)

Patch `~/.claude/hooks/session-start-resume.sh` (or the team-alpha
install) to skip injection when env var
`TEAM_ALPHA_ROLE` is set, OR when cwd matches a team-alpha role
dir, OR when `~/.team-alpha/<role>.password` mounted (container
mode):

```bash
if [ -n "$TEAM_ALPHA_ROLE" ]; then exit 0; fi
```

Pro: deterministic suppression. Con: edits global hook (operator's
non-team-alpha sessions still get resume prompts as today).

### C — Per-role `.claude/settings.json` hook override

Each role workspace ships its own `.claude/settings.json` that
disables the resume-prompt hook locally. Cleanest if Claude Code
respects per-project hook overrides.

## Recommendation

Ship A immediately (one-line addition to `_common.md`), then B as
a follow-up so it's enforced at the hook layer. C only if A+B
prove insufficient.

## Files

- `scripts/agent-prompts/_common.md` — add suppression section (A).
- `~/.claude/hooks/session-start-resume.sh` — env-gate (B).
- `scripts/hooks/install.sh` — set `TEAM_ALPHA_ROLE` in spawned
  role sessions if not already.

## Acceptance

- [ ] Cold maya session: first turn opens Monitor on
      `a2a.maya.tasks.send`, does NOT ask about resume prompts.
- [ ] Cold priya session: first turn calls `a2a_inbox()`, ditto.
- [ ] Operator's own (non-team-alpha) sessions still see the resume
      block.

## Refs

- T1 retest 2026-04-26 — empirical motivation.
- Card 210 — first-turn determinism contract.
- `~/.claude/hooks/session-start-resume.sh` — offending hook.
