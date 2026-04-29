---
branch: sun/refactor-cli-namespaces
commits:
  - "3ef41e9 feat(connect): local join without token"
  - "c736377 feat(connect): auto-enroll unknown role on local connect"
  - "0a67efa fix(connect): harden local auto-enroll (T1/T2/T3 from tim review)"
reviewer: joana
scope: joiner UX + operator safety
verdict: approved-with-comments
date: 2026-04-29
---

# Review: aon connect local join + auto-enroll (joiner angle)

## Verdict: approved-with-comments

Blockers from first pass (T1/T2/T3) all resolved in 0a67efa. Two non-blocking items remain; fine to merge, worth a follow-up.

## What's good

- Two-form dispatch (`aon://` = remote token, plain name = local operator) reads clearly.
- `local AON_TEAM_DIR` — correct scoping, no shell leak.
- `[y/N]` prompt with non-interactive default-N is the right default for an irreversible toml mutation.
- nsc pre-check before mutation prevents inconsistent state on nsc-missing operator machines.
- `bash -n` passes on clean branch.

## Resolved (0a67efa)

| ID | Item | Status |
|----|------|--------|
| T1 | no confirmation before auto-enroll | fixed — `[y/N]` prompt |
| T2 | aon.toml mutated before nsc pre-check | fixed — `command -v nsc` gating |
| T3 | `export AON_TEAM_DIR` leaks to parent shell | fixed — `local` keyword |

## Remaining non-blocking

### J1 — cmd_reinit full 3-step overkill for single new role

`cmd_reinit` (no args) in auto-enroll path triggers full reinit: auth-render + bootstrap + prompts-render for ALL roles. For adding one new role, `cmd_reinit "$_local_role"` (the per-role path) would suffice — lighter, no side-effects on existing roles.

Since the role is in toml after `cmd_add_role`, `cmd_reinit "$_local_role"` finds it and just issues the one JWT.

```bash
# Instead of:
cmd_reinit \

# Use:
cmd_reinit "$_local_role" \
```

### J2 — stale dev-note in cmd_add_role warn (line 153)

```
aon_warn "Templates not yet wired — run 'aon admin reinit' once Cards 234/235 land."
```

Internal task-tracker language leaks to users who hit auto-enroll path. Should be removed before GA. Proposed replacement: nothing, or "run 'aon admin reinit' to propagate prompt templates."

## Summary

Approve to merge. J1+J2 are paper-cut follow-ups — can be a single cleanup commit on a separate branch.
