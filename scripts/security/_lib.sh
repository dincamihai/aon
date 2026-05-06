#!/usr/bin/env bash
# Shared helpers for the cmd-gate stack. Sourced by cmd-gate.sh and
# its sublayers. Soft-fails on missing optional deps.

set -u

# ── Paths ──
GATE_ENGINE_DIR="${AON_ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GATE_POLICY_DIR="$GATE_ENGINE_DIR/scripts/security/policy"
GATE_LOCAL_DIR="${AON_GATE_LOCAL_DIR:-$HOME/.aon/security}"
GATE_CACHE_DIR="${AON_GATE_CACHE_DIR:-$HOME/.aon/cache/cmd-gate}"
GATE_LOG_FILE="${AON_GATE_LOG:-$HOME/.aon/cache/cmd-gate.log}"
mkdir -p "$GATE_CACHE_DIR" "$(dirname "$GATE_LOG_FILE")" 2>/dev/null || true

# ── Config (env-driven; aon.toml integration is a follow-up) ──
GATE_ENABLED="${AON_GATE_ENABLED:-1}"
# Bypass: env var OR marker file. Marker is required because Claude
# Code hooks inherit the launching shell's env, not env exported inside
# the agent's Bash calls — so toggling bypass after launch needs the
# marker to take effect.
#
# Sandbox-aware marker location. In the colima/AppArmor sandbox the
# agent's $HOME is writable by the agent — putting the marker there
# would let a misbehaving agent self-bypass. /etc/team-alpha/ is
# root-owned and the AppArmor profile denies agent writes to /etc/.
# When the sandbox is detected, ONLY the secure marker is honored;
# the in-HOME one is ignored. Operator on bare host (no sandbox)
# keeps the in-HOME marker.
GATE_BYPASS="${AON_GATE_BYPASS:-0}"
if [ -d /etc/team-alpha ]; then
  # Sandbox mode: secure marker only. Agent can't write /etc/.
  [ -e /etc/team-alpha/bypass ] && GATE_BYPASS=1
else
  # Bare host: in-HOME marker (operator owns $HOME).
  [ -e "$GATE_LOCAL_DIR/bypass" ] && GATE_BYPASS=1
fi
GATE_MODEL="${AON_GATE_MODEL:-nemotron-3-nano:4b}"
GATE_OLLAMA_URL="${AON_GATE_OLLAMA_URL:-http://127.0.0.1:11434}"
GATE_TIMEOUT_MS="${AON_GATE_TIMEOUT_MS:-4000}"
GATE_CACHE_TTL="${AON_GATE_CACHE_TTL:-3600}"
GATE_ASK_TIMEOUT="${AON_GATE_ASK_TIMEOUT:-60}"
GATE_FALLBACK="${AON_GATE_FALLBACK:-ask}"   # ask | deny | allow

# ── Logging (stderr only — Claude Code shows it on deny) ──
gate_log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s %s\n' "$ts" "$level" "$msg" >>"$GATE_LOG_FILE" 2>/dev/null || true
}

# ── Hash for cache keys ──
gate_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# ── Regex match helper. Skips comment lines and blanks. ──
gate_match_regex_file() {
  local file="$1" argv="$2"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if printf '%s' "$argv" | grep -E -q -- "$line"; then
      printf '%s' "$line"
      return 0
    fi
  done <"$file"
  return 1
}

# ── Emit Claude Code hook output ──
# allow: exit 0 silently
# deny:  exit 2 with reason on stderr
# ask:   stdout JSON with permissionDecision=ask, exit 0
gate_emit_allow() { exit 0; }

gate_emit_deny() {
  local reason="$1"
  printf 'cmd-gate: DENY — %s\n' "$reason" >&2
  exit 2
}

gate_emit_ask() {
  local reason="$1"
  jq -nc --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}
