#!/usr/bin/env bash
# Regression for `_aon_require_team_git`.
#
# Card: aon-require-team-git-rejects-worktrees (follow-up of PR #33).
# PR #33 used `[[ -d "$AON_TEAM_DIR/.git" ]]`, which spuriously rejects
# git worktrees (where `.git` is a gitlink FILE, not a dir). Fix swaps
# in a `git rev-parse --show-toplevel` + path equality check.
#
# Cases:
#   1. linked worktree            → pass
#   2. bare dir (no .git anywhere)→ hard-fail
#   3. subdir of repo whose .git
#      lives in parent (walk-up)  → hard-fail
#   4. regular checkout root      → pass

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../bin/_aon-lib.sh"
[[ -r "$LIB" ]] || { echo "✗ cannot find _aon-lib.sh at $LIB" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Need a fake $HOME with a .git so case 3 has somewhere to walk up to.
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"
git -C "$FAKE_HOME" init -q -b main
mkdir -p "$FAKE_HOME/sub/dir"

# Probe runs the helper in a subshell, no inherited env, captures rc.
# Using `bash -c` keeps the `exit 1` from killing this script.
probe() {
  local team="$1"
  HOME="$FAKE_HOME" AON_TEAM_DIR="$team" bash -c \
    "source '$LIB' >/dev/null 2>&1; _aon_require_team_git" \
    >/dev/null 2>&1
}

# 1. Regular checkout — pass.
REG="$WORK/regular"
git -C "$WORK" init -q -b main regular
probe "$REG"           || fail "regular checkout rejected (rc=$?)"
ok "regular checkout root accepted"

# 2. Linked worktree — pass.
WT="$WORK/wt-feature"
git -C "$REG" worktree add -q "$WT" -b wt-test 2>/dev/null
[[ -f "$WT/.git" ]]    || fail "expected gitlink file at $WT/.git"
probe "$WT"            || fail "linked worktree rejected (gitlink case)"
ok "linked worktree accepted (gitlink file)"

# 3. Bare dir — fail.
BARE="$WORK/bare"
mkdir -p "$BARE"
if probe "$BARE"; then
  fail "bare dir accepted (regression: walk-up prevention broken)"
fi
ok "bare dir rejected"

# 4. Subdir of git repo whose .git lives in parent — fail.
#    (The PR #33 walk-up case: $AON_TEAM_DIR sits inside $HOME/.git's
#    work-tree but is itself not the toplevel.)
if probe "$FAKE_HOME/sub/dir"; then
  fail "subdir of HOME/.git accepted (regression: walk-up to HOME)"
fi
ok "subdir-of-HOME rejected"

ok "ALL OK"
