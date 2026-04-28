#!/usr/bin/env bash
# Regression for `_aon_team_push` (engine helper used by `aon onboard`
# step 7/8). Card: aon-onboard-silently-masks-push-failure.
#
# Pre-fix `git push 2>&1 | tail -1 | grep -qiE 'rejected|error'` swallowed
# the real exit code and the `fatal:` line, so a no-remote push silently
# reported "✓ pushed". This test pins the four cases:
#
#   1. healthy remote      → rc=0
#   2. no remote           → rc!=0, fatal surfaced
#   3. broken remote       → rc!=0
#   4. rejected push (non-FF) → rc!=0
#
# Each case gets its own fresh AON_TEAM_DIR — no shared state.

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../bin/_aon-lib.sh"
[[ -r "$LIB" ]] || { echo "✗ cannot find _aon-lib.sh at $LIB" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

# Wrap a fresh shell around `_aon_team_push`. Returns rc + captured
# stderr. No `aon_fail` paths here — `_aon_team_push` only `aon_err`s.
push_probe() {
  local team="$1"
  AON_TEAM_DIR="$team" bash -c "
    source '$LIB' >/dev/null 2>&1
    _aon_team_push
  " 2>&1
}

# Helper: minimal repo with a single committed file.
mkrepo() {
  local d="$1"
  git init -q -b main "$d"
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# Helper: bare upstream so `push` can land.
mkbare() {
  git init -q --bare "$1"
}

# ── 1. healthy remote ──
HR_REPO="$WORK/healthy"; HR_BARE="$WORK/healthy.git"
mkrepo "$HR_REPO"; mkbare "$HR_BARE"
git -C "$HR_REPO" remote add origin "$HR_BARE"
git -C "$HR_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
git -C "$HR_REPO" push -q -u origin main 2>/dev/null  # establish upstream
git -C "$HR_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c2
out="$(push_probe "$HR_REPO")"; rc=$?
[[ $rc -eq 0 ]] || fail "healthy remote: expected rc=0, got rc=$rc; out:\n$out"
ok "healthy remote → rc=0"

# ── 2. no remote ──
NR_REPO="$WORK/no-remote"
mkrepo "$NR_REPO"
out="$(push_probe "$NR_REPO")"; rc=$?
[[ $rc -ne 0 ]] || fail "no remote: expected non-zero rc, got rc=0"
grep -qE "git push failed.*exit" <<<"$out" || fail "no remote: missing 'git push failed' surface; out:\n$out"
grep -qiE "no.*destination|no upstream|fatal" <<<"$out" || fail "no remote: missing fatal/destination text; out:\n$out"
ok "no remote → rc!=0, stderr surfaced"

# ── 3. broken remote ──
BR_REPO="$WORK/broken"
mkrepo "$BR_REPO"
git -C "$BR_REPO" remote add origin "/nonexistent/path/to/repo.git"
out="$(push_probe "$BR_REPO")"; rc=$?
[[ $rc -ne 0 ]] || fail "broken remote: expected non-zero rc, got rc=0"
grep -qE "git push failed.*exit" <<<"$out" || fail "broken remote: missing surface line; out:\n$out"
ok "broken remote → rc!=0"

# ── 4. rejected push (non-FF) ──
# Build two repos pointing at one bare; push from A so the bare's tip
# advances; have B's tip diverge → push from B is rejected.
RJ_BARE="$WORK/reject.git"; mkbare "$RJ_BARE"
RJ_A="$WORK/reject-a"; RJ_B="$WORK/reject-b"
mkrepo "$RJ_A"
git -C "$RJ_A" remote add origin "$RJ_BARE"
git -C "$RJ_A" -c user.email=t@t -c user.name=t commit -q --allow-empty -m a1
git -C "$RJ_A" push -q -u origin main 2>/dev/null
# clone-style B pointing at same bare, but with its own divergent commit
git clone -q "$RJ_BARE" "$RJ_B"
git -C "$RJ_B" -c user.email=t@t -c user.name=t commit -q --allow-empty -m b1
# advance A again so B is non-FF
git -C "$RJ_A" -c user.email=t@t -c user.name=t commit -q --allow-empty -m a2
git -C "$RJ_A" push -q origin main 2>/dev/null
# B now diverges from origin/main; force B onto a different commit so
# its push is non-FF rejected
out="$(push_probe "$RJ_B")"; rc=$?
[[ $rc -ne 0 ]] || fail "rejected push: expected non-zero rc, got rc=0"
grep -qE "git push failed.*exit" <<<"$out" || fail "rejected push: missing surface; out:\n$out"
grep -qiE "rejected|non-fast-forward|fetch first" <<<"$out" || fail "rejected push: missing reject text; out:\n$out"
ok "rejected push (non-FF) → rc!=0"

ok "ALL OK"
