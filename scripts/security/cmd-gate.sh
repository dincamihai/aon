#!/usr/bin/env bash
# Layered command safety gate. Entry point for the PreToolUse hook.
#
# Reads Claude Code hook JSON on stdin. For Bash tool calls,
# extracts tool_input.command and runs:
#   1. enabled / bypass checks
#   2. cache lookup
#   3. deny.local.regex  (user override, always-deny)
#   4. deny.regex        (hard floor)
#   5. allow.local.regex (user override, always-allow)
#   6. allow.regex       (fast path)
#   7. ollama classifier
#   8. on classifier=ask → operator-ask over NATS, with timeout
#
# Exits per Claude Code hook contract:
#   exit 0          → allow
#   exit 2 + stderr → deny
#   stdout JSON     → ask (rare; operator-ask blocks here so
#                     we usually resolve to allow/deny)

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/_lib.sh"

# Read stdin (Claude Code hook envelope)
input="$(cat)"
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case "$tool" in
  Bash) ;;
  Read|Write|Edit|MultiEdit)
    # Narrow check for credential paths in path-bearing tools
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    case "$path" in
      */.ssh/*|*/.aws/credentials|*/.aws/config|*/.env*|/etc/shadow|/etc/sudoers)
        bash "$HERE/audit.sh" "$tool:$path" deny credential-read \
          "$tool against credential path" deny.regex >/dev/null 2>&1 || true
        gate_emit_deny "credential-bearing path blocked: $path"
        ;;
    esac
    gate_emit_allow
    ;;
  *) gate_emit_allow ;;
esac

argv=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$argv" ] && gate_emit_allow

# Globally disabled?
if [ "$GATE_ENABLED" != "1" ]; then
  bash "$HERE/audit.sh" "$argv" allow disabled "gate disabled" disabled \
    >/dev/null 2>&1 || true
  gate_emit_allow
fi

# Hard floor checks ALWAYS run, even with bypass.
if hit=$(gate_match_regex_file "$GATE_LOCAL_DIR/deny.local.regex" "$argv"); then
  bash "$HERE/audit.sh" "$argv" deny user-deny "deny.local: $hit" deny.local \
    >/dev/null 2>&1 || true
  gate_emit_deny "deny.local match: $hit"
fi

if hit=$(gate_match_regex_file "$GATE_POLICY_DIR/deny.regex" "$argv"); then
  bash "$HERE/audit.sh" "$argv" deny hard-deny "deny.regex: $hit" deny.regex \
    >/dev/null 2>&1 || true
  gate_emit_deny "deny.regex match: $hit"
fi

# Bypass: skip remaining classifier work, allow everything not hard-denied
if [ "$GATE_BYPASS" = "1" ]; then
  bash "$HERE/audit.sh" "$argv" allow bypass "AON_GATE_BYPASS=1" bypass \
    >/dev/null 2>&1 || true
  gate_emit_allow
fi

# Cache lookup
hash=$(gate_hash "$argv")
if cached=$(bash "$HERE/cache.sh" get "$hash" 2>/dev/null); then
  v=$(printf '%s' "$cached" | jq -r '.verdict')
  r=$(printf '%s' "$cached" | jq -r '.reason')
  c=$(printf '%s' "$cached" | jq -r '.category')
  bash "$HERE/audit.sh" "$argv" "$v" "$c" "$r" cache >/dev/null 2>&1 || true
  case "$v" in
    allow) gate_emit_allow ;;
    deny)  gate_emit_deny "$r" ;;
    ask)   ;;  # do not cache ask; fall through and re-resolve
  esac
fi

# User allow override
if hit=$(gate_match_regex_file "$GATE_LOCAL_DIR/allow.local.regex" "$argv"); then
  bash "$HERE/audit.sh" "$argv" allow user-allow "allow.local: $hit" allow.local \
    >/dev/null 2>&1 || true
  bash "$HERE/cache.sh" put "$hash" \
    "$(jq -nc --arg r "allow.local" '{verdict:"allow",category:"user-allow",reason:$r}')" \
    >/dev/null 2>&1 || true
  gate_emit_allow
fi

# Allow regex fast path
if hit=$(gate_match_regex_file "$GATE_POLICY_DIR/allow.regex" "$argv"); then
  bash "$HERE/audit.sh" "$argv" allow read-only "allow.regex: $hit" allow.regex \
    >/dev/null 2>&1 || true
  bash "$HERE/cache.sh" put "$hash" \
    "$(jq -nc --arg r "allow.regex" '{verdict:"allow",category:"read-only",reason:$r}')" \
    >/dev/null 2>&1 || true
  gate_emit_allow
fi

# Classifier
verdict_json=$(printf '%s' "$argv" | bash "$HERE/classifier-ollama.sh")
v=$(printf '%s' "$verdict_json" | jq -r '.verdict')
c=$(printf '%s' "$verdict_json" | jq -r '.category')
r=$(printf '%s' "$verdict_json" | jq -r '.reason')

case "$v" in
  allow)
    bash "$HERE/cache.sh" put "$hash" "$verdict_json" >/dev/null 2>&1 || true
    bash "$HERE/audit.sh" "$argv" allow "$c" "$r" classifier \
      >/dev/null 2>&1 || true
    gate_emit_allow
    ;;
  deny)
    # Classifier deny is high-confidence — deny immediately.
    # No operator-ask; the hard floor (deny.regex) already caught
    # irreversible ops above. This handles medium-confidence destructive
    # commands the classifier is sure about.
    bash "$HERE/audit.sh" "$argv" deny "$c" "classifier deny: $r" classifier \
      >/dev/null 2>&1 || true
    gate_emit_deny "classifier=$v: $r"
    ;;
  ask|*)
    # Ambiguous — route to operator for human judgment.
    bash "$HERE/audit.sh" "$argv" "$v" "$c" "classifier prior: $r" classifier \
      >/dev/null 2>&1 || true
    ask_reason="$c — $r"
    if reply=$(bash "$HERE/operator-ask.sh" "$argv" "$c" "$ask_reason" 2>/dev/null); then
      d=$(printf '%s' "$reply" | jq -r '.decision')
      op=$(printf '%s' "$reply" | jq -r '.operator // "unknown"')
      orsn=$(printf '%s' "$reply" | jq -r '.reason // ""')
      bash "$HERE/audit.sh" "$argv" "$d" "$c" "operator=$op classifier=$v orsn=$orsn" operator \
        >/dev/null 2>&1 || true
      case "$d" in
        allow) gate_emit_allow ;;
        deny)  gate_emit_deny "operator denied: ${orsn:-no reason}" ;;
      esac
    fi
    # operator-ask failed (NATS down, no operator, timeout) → fallback
    bash "$HERE/audit.sh" "$argv" "$GATE_FALLBACK" "$c" \
      "operator-ask failed (classifier=$v); fallback=$GATE_FALLBACK" fallback \
      >/dev/null 2>&1 || true
    case "$GATE_FALLBACK" in
      allow) gate_emit_allow ;;
      deny|*)  gate_emit_deny "fallback=deny (classifier=$v): $r" ;;
    esac
    ;;
esac
