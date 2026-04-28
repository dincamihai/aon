---
column: In Progress
created: 2026-04-28
priority: high
parent: aon-onboard-walks-up-to-home-git
follow_up_of: PR#33
discovered_by: rona (exploratory)
severity: med
---

# `_aon_require_team_git` + `cmd_doctor` reject git worktrees

## Bug

Both `_aon_require_team_git` (bin/_aon-lib.sh L42) and `cmd_doctor`
(bin/aon L190) test `[[ -d "$AON_TEAM_DIR/.git" ]]`. In a git
**worktree**, `.git` is a regular FILE — a gitlink with
`gitdir: /path/to/main/.git/worktrees/<name>`. The `-d` test fails
spuriously, hard-failing on a perfectly valid checkout.

## Repro

```bash
git -C /tmp/rona-explore/main-repo worktree add /tmp/rona-explore/wt-test -b feature
AON_TEAM_DIR=/tmp/rona-explore/wt-test bash -c \
  'source bin/_aon-lib.sh; _aon_require_team_git'
# expected: pass
# observed: ✗ team-aon repo at <path> is not a git repo
#           ✗ refusing git operations to avoid walking up to $HOME/.git

aon doctor   # same false-positive
```

## Impact

Any operator running `aon onboard` / `aon doctor` from a worktree on
the team-aon repo gets blocked. `agent-prompts/_common.md` L150-163
recommends worktrees per agent — so this hits the happy path, not an
edge.

## Fix

Swap `[[ -d "$AON_TEAM_DIR/.git" ]]` for `[[ -e "$AON_TEAM_DIR/.git" ]]`
(file or dir). Still prevents walk-up to `$HOME/.git`: absent file +
absent dir = hard-fail.

Stronger alternative (preferred): use `git -C "$AON_TEAM_DIR"
rev-parse --show-toplevel` and confirm it equals `$AON_TEAM_DIR`.
Catches the symlink and walk-up cases in one check, and naturally
accepts both regular repos and worktrees.

## Acceptance

1. `_aon_require_team_git` passes when `$AON_TEAM_DIR` is a git
   worktree (gitlink file).
2. Hard-fail still triggers when `$AON_TEAM_DIR/.git` is absent
   entirely (regression: walk-up prevention preserved).
3. Hard-fail still triggers when `$AON_TEAM_DIR` is a subdir whose
   nearest `.git` is `$HOME` (regression from PR #33).
4. `cmd_doctor` mirrors the same logic — no false-positive on
   worktrees.
5. Regression test added in `scripts/nsc-smoke/` (or fixture):
   - worktree case → pass
   - bare-dir case → hard-fail
   - subdir-with-HOME-walk-up case → hard-fail
6. `scripts/nsc-smoke/run-smoke.sh` Phase C green.

## Out of scope

- Multi-worktree state in `aon doctor` (e.g. detect stale worktrees) —
  separate concern.
- Submodules (different beast; not used in workers/aon flows).

## Gate

`scripts/nsc-smoke/run-smoke.sh` Phase C.
