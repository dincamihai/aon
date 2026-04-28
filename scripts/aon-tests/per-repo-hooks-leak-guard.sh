#!/usr/bin/env bash
# Pin the `aon doctor` leak-guard for committed per-repo
# .claude/settings.json (card per-repo-hooks-install, design call:
# commit by default; portability verified at every doctor run).
#
# Cases:
#   1. clean settings.json (only `aon hook NAME` / `aon mcp-server`
#      commands) → doctor PASS, no warn, no bad
#   2. settings.json with absolute path command → doctor FAIL with
#      "abs path leaked" surface (joiners would pull operator path)
#   3. settings.json with non-aon command → doctor warns
#      ("non-team command") but still PASS (operator intent
#      possible)
#
# Each case spins up a fresh team-aon dir + work-repo registered in a
# scratch ~/.aon. doctor runs against that registry.

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

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.aon" "$FAKE_HOME/.claude"

TEAM="$WORK/team"
mkdir -p "$TEAM"
cat > "$TEAM/aon.toml" <<'TOML'
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

# Build a work-repo + register it so `_aon_resolve_from_cwd` returns
# (team, role, repo) and doctor's per-repo block fires.
WR="$WORK/work-repo"
git init -q -b main "$WR"
mkdir -p "$WR/.claude"
cat > "$FAKE_HOME/.aon/work-repos.json" <<JSON
[{"path": "$WR", "team": "fixture", "role": "tim"}]
JSON

run_doctor() {
  HOME="$FAKE_HOME" AON_TEAM_DIR="$TEAM" "$AON" doctor 2>&1
}

# ── Case 1: clean ──
cat > "$WR/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{
      "matcher": "*",
      "hooks": [
        {"type":"command","command":"eval $(aon resolve-env) && aon hook session-start-onboard"}
      ]
    }]
  }
}
JSON
( cd "$WR" && out="$(run_doctor)" )
out="$(cd "$WR" && run_doctor || true)"
grep -qE "abs path leaked" <<<"$out" && fail "case 1 (clean): bad surface fired"
grep -qE "non-team command" <<<"$out" && fail "case 1 (clean): warn surface fired"
grep -qE "per-repo hooks present" <<<"$out" || fail "case 1 (clean): expected 'per-repo hooks present'; got: $out"
ok "case 1 clean → doctor accepts, no bad, no warn"

# ── Case 2: abs path leaked ──
cat > "$WR/.claude/settings.json" <<JSON
{
  "hooks": {
    "SessionStart": [{
      "matcher": "*",
      "hooks": [
        {"type":"command","command":"bash /Users/operator/Repos/ai-over-nats/scripts/hooks/session-start-onboard.sh"}
      ]
    }]
  }
}
JSON
out="$(cd "$WR" && run_doctor || true)"
grep -qE "abs path leaked" <<<"$out" || fail "case 2 (abs path): expected 'abs path leaked' bad; got: $out"
ok "case 2 abs path → doctor reports 'abs path leaked'"

# ── Case 3: non-team command ──
cat > "$WR/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{
      "matcher": "*",
      "hooks": [
        {"type":"command","command":"echo operator-added-something"}
      ]
    }]
  }
}
JSON
out="$(cd "$WR" && run_doctor || true)"
grep -qE "non-team command" <<<"$out" || fail "case 3 (non-team): expected 'non-team command' warn; got: $out"
grep -qE "abs path leaked" <<<"$out" && fail "case 3 (non-team): false-positive abs-path bad"
ok "case 3 non-team → doctor warns 'non-team command'"

ok "ALL OK"
