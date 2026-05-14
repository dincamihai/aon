#!/usr/bin/env bash
# Regression for global hook install model (ref: PR #112, issue #113).
#
# Pre-PR #112: hooks lived in <work_repo>/.claude/settings.json.
# Post-PR #112: hooks live in ~/.claude/settings.json (global) with an
# aon.toml dir guard that makes them no-ops outside aon repos.
#
# Cases:
#   1. install.sh global writes hooks into ~/.claude/settings.json
#   2. No hooks written to <work_repo>/.claude/settings.json
#   3. aon.toml guard — hook _lib.sh exits 0 outside an aon repo
#   4. install.sh check reflects global state (passes after global install)
#   5. install.sh uninstall strips only aon entries, preserves non-aon hooks

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../.."
INSTALL="$ENGINE/scripts/hooks/install.sh"
LIB="$ENGINE/scripts/hooks/_lib.sh"
[[ -x "$INSTALL" ]] || { echo "✗ no install.sh at $INSTALL" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude"

# Work-repo without aon.toml (used for the guard test).
WR="$WORK/work-repo"
git init -q -b main "$WR"

# Aon-repo with aon.toml (used to verify guard passes for real repos).
AON_REPO="$WORK/aon-repo"
git init -q -b main "$AON_REPO"
cat > "$AON_REPO/aon.toml" <<'TOML'
[engine]
version = "0.1"
[team]
name = "fixture"
[nats]
url = "nats://fixture:4222"
[paths]
task_dir    = ".tasks"
prompts_dir = "agent-prompts"
agents_dir  = "agents"
hooks_dir   = "hooks"
TOML

GLOBAL_SETTINGS="$FAKE_HOME/.claude/settings.json"

# 1. install.sh global writes hooks into ~/.claude/settings.json.
HOME="$FAKE_HOME" bash "$INSTALL" global >/dev/null \
  || fail "install.sh global exited non-zero"
[[ -f "$GLOBAL_SETTINGS" ]] || fail "expected $GLOBAL_SETTINGS after global install"
event_count="$(jq '.hooks | keys | length' "$GLOBAL_SETTINGS")"
[[ "$event_count" -ge 5 ]] || fail "expected ≥5 hook events, got $event_count"
ok "install.sh global writes hooks to ~/.claude/settings.json ($event_count events)"

# 2. No hooks written to work-repo .claude/settings.json.
[[ ! -f "$WR/.claude/settings.json" ]] \
  || fail "hooks leaked into work-repo .claude/settings.json"
ok "no per-repo .claude/settings.json written"

# 3. aon.toml guard — _lib.sh exits 0 (no-op) outside an aon repo.
out="$(PWD="$WR" HOOK_REPO_ROOT="$WR" AON_ROLE=sun bash "$LIB" 2>&1)"
rc=$?
[[ $rc -eq 0 ]] || fail "_lib.sh non-zero exit ($rc) outside aon repo; expected 0"
[[ -z "$out" ]] || fail "_lib.sh produced output outside aon repo: $out"
ok "aon.toml guard: _lib.sh is no-op outside aon repo (exit 0, no output)"

# 4. install.sh check reflects global state.
HOME="$FAKE_HOME" bash "$INSTALL" check >/dev/null \
  || fail "install.sh check failed after global install"
ok "install.sh check passes after global install"

# 5. install.sh uninstall strips aon entries, preserves non-aon hooks.
# Seed global settings with a mix: aon hook entry + non-aon entry on same event.
cat > "$GLOBAL_SETTINGS" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook session-start-onboard" },
          { "type": "command", "command": "echo keepme-non-aon" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook stop" }
        ]
      }
    ]
  }
}
JSON
HOME="$FAKE_HOME" bash "$INSTALL" uninstall >/dev/null \
  || fail "install.sh uninstall exited non-zero"

# aon hook entries gone.
aon_count="$(jq '[.. | strings | select(test("aon hook"))] | length' "$GLOBAL_SETTINGS")"
[[ "$aon_count" -eq 0 ]] || fail "aon hook entries still present after uninstall ($aon_count)"
ok "install.sh uninstall removes all aon hook entries"

# non-aon entry preserved.
keepme="$(jq -r '[.. | strings | select(test("keepme-non-aon"))] | first // ""' "$GLOBAL_SETTINGS")"
[[ "$keepme" == "echo keepme-non-aon" ]] \
  || fail "non-aon hook entry lost after uninstall; settings: $(cat "$GLOBAL_SETTINGS")"
ok "install.sh uninstall preserves non-aon hooks in same matcher block"

# Stop key removed (array empty after strip).
stop_present="$(jq 'has("hooks") and (.hooks | has("Stop"))' "$GLOBAL_SETTINGS")"
[[ "$stop_present" == "false" ]] \
  || fail "empty Stop array not cleaned up; settings: $(cat "$GLOBAL_SETTINGS")"
ok "install.sh uninstall removes empty event keys"

ok "ALL OK"
