#!/usr/bin/env bash
# Regression test: cursor isolation on multi-role hosts (F5).
# Starting hook for role X must not touch cursors for other rostered roles.
set -euo pipefail

FAIL=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CURSOR_DIR="$TMP/cursors"
mkdir -p "$CURSOR_DIR"

# Minimal aon.toml with two rostered roles + [team].name to verify we don't
# accidentally pick up non-role names.
cat > "$TMP/aon.toml" <<'EOF'
[team]
name = "workers"

[[roles]]
name = "tim"
kind = "generalist"

[[roles]]
name = "joana"
kind = "generalist"
EOF

# Pre-populate cursor files: both rostered roles + one ex-member.
echo "2026-04-28T10:00:00Z" > "$CURSOR_DIR/last-seen-tim"
echo "2026-04-28T10:00:00Z" > "$CURSOR_DIR/last-seen-joana"
echo "2026-04-28T10:00:00Z" > "$CURSOR_DIR/last-seen-orphan"

# Reproduce the cleanup logic from _lib.sh for role=tim.
HOOK_ROLE="tim"
HOOK_REPO_ROOT="$TMP"

_hook_roster_from_toml() {
  local toml="$HOOK_REPO_ROOT/aon.toml"
  [ -f "$toml" ] || return
  awk '/^\[\[roles/{r=1;next} /^\[/{r=0;next} r && /^[[:space:]]*name[[:space:]]*=/{
    gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); print
  }' "$toml"
}

for _stale_cursor in "$CURSOR_DIR"/last-seen-*; do
  [ -f "$_stale_cursor" ] || continue
  _stale_role="${_stale_cursor##*last-seen-}"
  [ "$_stale_role" = "$HOOK_ROLE" ] && continue
  _hook_roster_from_toml | grep -qxF "$_stale_role" || rm -f "$_stale_cursor" 2>/dev/null || true
done

# AC1: own cursor intact.
[ -f "$CURSOR_DIR/last-seen-tim" ]   && pass "AC1: own cursor preserved"   || fail "AC1: own cursor deleted"
# AC1: peer rostered cursor intact.
[ -f "$CURSOR_DIR/last-seen-joana" ] && pass "AC1: peer cursor preserved"  || fail "AC1: peer cursor WIPED (regression F5)"
# AC2: orphan (not in roster) removed.
[ ! -f "$CURSOR_DIR/last-seen-orphan" ] && pass "AC2: orphan cursor pruned" || fail "AC2: orphan cursor not pruned"

# Verify [team].name is NOT treated as a role name (would preserve orphan if it matched).
rostered=$(_hook_roster_from_toml | sort | tr '\n' ' ')
[[ "$rostered" != *"workers"* ]] && pass "parser skips [team].name" || fail "parser leaked [team].name into roster"

if [ "$FAIL" -eq 0 ]; then
  echo "All cursor-isolation tests passed."
  exit 0
else
  echo "One or more tests FAILED." >&2
  exit 1
fi
