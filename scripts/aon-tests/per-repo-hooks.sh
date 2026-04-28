#!/usr/bin/env bash
# Regression for per-repo hooks install (card per-repo-hooks-install).
#
# Pre-fix: hook commands lived in ~/.claude/settings.json (global) and
# fired for every claude session on the host. Fix moves them into
# <work_repo>/.claude/settings.json with portable `aon hook <name>`
# commands and a migration to strip stale globals.
#
# Cases:
#   1. _aon_install_repo_mcp writes hooks into <work_repo>/.claude/settings.json
#   2. Commands rewritten to `eval $(aon resolve-env) && aon hook <name>`
#      (no operator-absolute path baked in)
#   3. Pre-existing legacy team hooks in ~/.claude/settings.json are
#      stripped by the migration block; non-team keys preserved
#   4. .claude/settings.json added to <work_repo>/.gitignore
#   5. `aon hook <name>` rejects unknown name with rc=1 + directive

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../.."
AON="$ENGINE/bin/aon"
[[ -x "$AON" ]] || { echo "✗ no aon at $AON" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake $HOME so we don't touch the real ~/.claude/settings.json.
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude"

# Seed legacy team hooks + a non-team hook in fake global. Migration
# must strip the team ones, preserve the non-team one.
cat > "$FAKE_HOME/.claude/settings.json" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash $ENGINE/scripts/hooks/session-start-onboard.sh" },
          { "type": "command", "command": "echo unrelated-keepme" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash $ENGINE/scripts/hooks/stop.sh" }
        ]
      }
    ]
  }
}
JSON

# Fake work-repo with .git.
WR="$WORK/work-repo"
git init -q -b main "$WR"

# Run the install via a sourced library so we can hit the helper
# directly without standing up a real team.
HOME="$FAKE_HOME" bash <<EOF
set -e
source "$ENGINE/bin/_aon-lib.sh"
AON_TEAM_DIR="$WORK/team"
mkdir -p "\$AON_TEAM_DIR"
cat > "\$AON_TEAM_DIR/aon.toml" <<'TOML'
[engine]
version = "0.1"
[team]
name = "fixture"
[nats]
url = "nats://fixture:4222"
[paths]
task_dir = ".tasks"
prompts_dir = "agent-prompts"
agents_dir = "agents"
hooks_dir = "hooks"
TOML
aon_load_config

# We need just the hooks-install block of _aon_install_repo_mcp without
# all the venv/MCP-server setup, so source aon and call the helper.
# Skip MCP venv steps by short-circuiting:
export BOARD_TUI_MCP_BIN=/usr/bin/true   # bypass pipx detection

# Fake the venv check so the helper proceeds.
mkdir -p "$ENGINE/mcp-server/.venv/bin"
[[ -x "$ENGINE/mcp-server/.venv/bin/aon-mcp" ]] || cp /usr/bin/true "$ENGINE/mcp-server/.venv/bin/aon-mcp"

# Source aon as a library: each cmd_* is defined; we call the helper.
# But aon's tail dispatches on \$1; suppress by passing 'help' which
# returns. Capture into a no-op pipe so the dispatch runs and we still
# have functions resolved. Easier: copy just the helper into a tmp
# file and source it.
EOF

# Easier path: invoke the helper through `aon join` would require a
# full team. Instead exercise the install logic via a focused harness
# that sources aon.bin's functions. We do this by running aon as a
# subshell with a stub command.

# Helper: source aon's function definitions without the dispatch tail.
strip_dispatch() {
  # Take everything up to (but not including) the top-level dispatch
  # `case "${1:-}" in`, AND drop the `source _aon-lib.sh` line at the
  # top so a separate pre-source can load the lib from its real path.
  sed -n '1,/^case "${1:-}" in$/{/^case "${1:-}" in$/!p;}' "$AON" \
    | sed -e '/^_aon_dir=/d' -e '/source "\$_aon_dir\/_aon-lib\.sh"/d'
}

LIB_FILE="$WORK/aon-lib.sh"
strip_dispatch > "$LIB_FILE"

# Build a fake engine dir: real `bin/aon` (for the `aon hook` rc=1
# probe later), real scripts/hooks (linked), but our own
# .claude/settings.json fixture so the test isn't sensitive to
# whatever the real engine ships at HEAD.
FAKE_ENGINE="$WORK/fake-engine"
mkdir -p "$FAKE_ENGINE/.claude" "$FAKE_ENGINE/bin" "$FAKE_ENGINE/mcp-server/.venv/bin"
ln -s "$ENGINE/scripts" "$FAKE_ENGINE/scripts"
ln -s "$ENGINE/bin/_aon-lib.sh" "$FAKE_ENGINE/bin/_aon-lib.sh"
ln -s "$ENGINE/bin/aon" "$FAKE_ENGINE/bin/aon"
cp /usr/bin/true "$FAKE_ENGINE/mcp-server/.venv/bin/aon-mcp"

# Engine-side hook fixture: one event with two abs-path commands.
cat > "$FAKE_ENGINE/.claude/settings.json" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash $FAKE_ENGINE/scripts/hooks/session-start-onboard.sh" },
          { "type": "command", "command": "bash $FAKE_ENGINE/scripts/hooks/stop.sh arg1 arg2" }
        ]
      }
    ]
  }
}
JSON

# Run install in fake-HOME subshell.
mkdir -p "$WORK/team"
cat > "$WORK/team/aon.toml" <<'TOML'
[engine]
version = "0.1"
[team]
name = "fixture"
[nats]
url = "nats://fixture:4222"
[paths]
task_dir = ".tasks"
prompts_dir = "agent-prompts"
agents_dir = "agents"
hooks_dir = "hooks"
TOML

# Source the engine lib + aon function defs (with dispatch tail
# stripped) so `_aon_install_repo_mcp` is in scope. AON_ENGINE_DIR
# is forced so the lib's auto-detect doesn't pick up $LIB_FILE's
# location.
HOME="$FAKE_HOME" \
AON_ENGINE_DIR="$FAKE_ENGINE" \
AON_TEAM_DIR="$WORK/team" \
BOARD_TUI_MCP_BIN=/usr/bin/true \
bash -c "
  set -e
  source '$ENGINE/bin/_aon-lib.sh'
  source '$LIB_FILE'
  aon_load_config
  _aon_install_repo_mcp '$FAKE_ENGINE' '$WR'
" >"$WORK/install.log" 2>&1 || { cat "$WORK/install.log" >&2; fail "_aon_install_repo_mcp errored"; }

# 1. Per-repo settings.json exists.
[[ -f "$WR/.claude/settings.json" ]] || fail "expected $WR/.claude/settings.json"
ok "per-repo .claude/settings.json written"

# 2. Commands are portable: `aon hook <name>` (no engine abs path).
if jq -e '.hooks // {} | to_entries | map(.value[]?.hooks[]?.command? // "") | map(select(test("^eval \\$\\(aon resolve-env\\) && aon hook "))) | length > 0' \
     "$WR/.claude/settings.json" >/dev/null 2>&1; then
  ok "hook commands rewritten to 'eval \$(aon resolve-env) && aon hook <name>'"
else
  fail "hook commands not rewritten; got: $(jq '.hooks' "$WR/.claude/settings.json")"
fi
if jq -e '.hooks // {} | to_entries | map(.value[]?.hooks[]?.command? // "") | map(select(test("scripts/hooks/.*\\.sh"))) | length > 0' \
     "$WR/.claude/settings.json" >/dev/null 2>&1; then
  fail "absolute scripts/hooks/*.sh path leaked into per-repo settings"
fi
ok "no engine absolute path baked into per-repo settings"

# 3. Migration stripped legacy team hooks, kept non-team.
if jq -e '.hooks.SessionStart // [] | map(.hooks[]?.command? // "") | map(select(test("scripts/hooks/|aon hook"))) | length > 0' \
     "$FAKE_HOME/.claude/settings.json" >/dev/null 2>&1; then
  fail "legacy team hooks still in fake global ~/.claude/settings.json after migration"
fi
ok "legacy team hooks stripped from global"
if jq -e '.hooks.SessionStart // [] | map(.hooks[]?.command? // "") | map(select(test("unrelated-keepme"))) | length > 0' \
     "$FAKE_HOME/.claude/settings.json" >/dev/null 2>&1; then
  ok "non-team global hook preserved"
else
  fail "migration over-pruned: non-team global hook lost"
fi

# 4. .claude/settings.json is COMMITTED (not gitignored) per design call.
if grep -qxE '\.claude/settings\.json|/\.claude/settings\.json' "$WR/.gitignore" 2>/dev/null; then
  fail ".claude/settings.json gitignored — design call is commit-by-default; portability enforced at write + verified by doctor"
fi
ok ".claude/settings.json not gitignored (commit-by-default per design call)"

# 5. `aon hook <unknown>` rejects with rc=1.
out="$("$AON" hook nonexistent-hook 2>&1)" && fail "aon hook unknown returned rc=0"
rc=$?
[[ "$rc" -eq 1 ]] || fail "aon hook unknown rc=$rc, expected 1"
grep -qE "no hook script" <<<"$out" || fail "missing 'no hook script' surface"
ok "aon hook <unknown> → rc=1 + directive"

ok "ALL OK"
