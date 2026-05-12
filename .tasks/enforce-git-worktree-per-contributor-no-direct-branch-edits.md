---
column: Backlog
---

# Enforce git worktree per contributor — no direct branch edits
## Problem

Multiple contributors editing the same branch directly causes merge conflicts and forces cherry-picks. Observed this session: rona testing on `rona/pr62-e2e`, joana reviewing, sun committing fixes — all to overlapping branches, causing repeated cherry-pick conflicts.

## Rule

**Every contributor works in a dedicated git worktree. No direct commits to a shared branch.**

```bash
# Before starting any work:
git worktree add ../ai-over-nats-<name>-<task> -b <name>/<task>
cd ../ai-over-nats-<name>-<task>
# do work, commit, push
# open PR into target branch
```

## Agent workflow

- Reviewer (joana/tim): worktree for review notes / fix PRs
- Tester (rona): worktree for e2e results commits
- Sun: worktree for each fix batch

## Enforcement options

1. Document in CONTRIBUTING.md / agent-prompts
2. `aon admin` could scaffold a worktree as part of task pickup
3. Pre-commit hook warns if HEAD branch is a shared/protected branch

## Immediate action

- Add worktree rule to `agent-prompts/_common.md` git workflow section
- Add to `templates/agent-prompts/_common.md.tmpl`
