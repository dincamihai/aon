#!/usr/bin/env bash
# Regression: global hook install must not bake absolute paths into
# ~/.claude/settings.json (ref: PR #112, issue #113).
#
# Pre-PR #112: abs paths could leak via per-repo install.
# Post-PR #112: global install uses portable `aon hook X` form only.
#
# Cases:
#   1. After install.sh global — no abs paths in global settings
#   2. install.sh global is idempotent — running twice yields no duplicates
#   3. Non-aon hooks in global settings survive install.sh global (no clobber)

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../.."
INSTALL="$ENGINE/scripts/hooks/install.sh"
[[ -x "$INSTALL" ]] || { echo "✗ no install.sh at $INSTALL" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude"
GLOBAL_SETTINGS="$FAKE_HOME/.claude/settings.json"

# 1. No abs paths after install.sh global.
HOME="$FAKE_HOME" bash "$INSTALL" global >/dev/null \
  || fail "install.sh global exited non-zero"

abs_count="$(jq '[.. | strings | select(test("^(bash |/|eval.*scripts/hooks/)"))] | length' "$GLOBAL_SETTINGS")"
[[ "$abs_count" -eq 0 ]] \
  || fail "absolute path found in global settings after install ($abs_count entries): $(jq '[.. | strings | select(test("^(bash |/|eval.*scripts/hooks/)"))]' "$GLOBAL_SETTINGS")"
ok "no absolute paths in global settings after install"

# All hook commands use aon hook form.
aon_hook_count="$(jq '[.. | strings | select(test("aon hook"))] | length' "$GLOBAL_SETTINGS")"
[[ "$aon_hook_count" -gt 0 ]] || fail "no 'aon hook' commands found after install"
ok "all hook commands use portable 'aon hook X' form ($aon_hook_count entries)"

# 2. Idempotent — running global twice yields same hook count, no duplicates.
HOME="$FAKE_HOME" bash "$INSTALL" global >/dev/null \
  || fail "install.sh global (second run) exited non-zero"
aon_hook_count2="$(jq '[.. | strings | select(test("aon hook"))] | length' "$GLOBAL_SETTINGS")"
[[ "$aon_hook_count2" -eq "$aon_hook_count" ]] \
  || fail "duplicate hooks after second install: $aon_hook_count → $aon_hook_count2"
ok "install.sh global is idempotent (no duplicates on re-run)"

# 3. Non-aon hooks survive install.sh global — no clobber.
# Seed a non-aon hook on SessionStart, then re-run global.
FAKE_HOME2="$WORK/home2"
mkdir -p "$FAKE_HOME2/.claude"
cat > "$FAKE_HOME2/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "echo caveman-plugin-hook" }
        ]
      }
    ]
  }
}
JSON
HOME="$FAKE_HOME2" bash "$INSTALL" global >/dev/null \
  || fail "install.sh global over existing settings exited non-zero"

keepme="$(jq -r '[.. | strings | select(test("caveman-plugin-hook"))] | first // ""' "$FAKE_HOME2/.claude/settings.json")"
[[ "$keepme" == "echo caveman-plugin-hook" ]] \
  || fail "non-aon plugin hook clobbered by global install"
ok "non-aon hooks survive install.sh global (no clobber)"

ok "ALL OK"
