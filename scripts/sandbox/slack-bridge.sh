#!/usr/bin/env bash
# slack-bridge.sh — tail Slack JSONL events from slack-mcp-rtm and republish
# them onto a NATS subject so an aon agent (e.g. Sun) sees them via her
# regular monitor.
#
# Usage:
#   slack-bridge.sh                    # default role: sun (subject agents.sun.inbox)
#   slack-bridge.sh tim                # custom role
#   SLACK_EVENTS_SINK=/path/file.jsonl slack-bridge.sh
#
# Behaviour:
#   - singleton per role (flock on /tmp/slack-bridge-<role>.lock)
#   - tails the sink file from the end (does not replay backlog)
#   - publishes each event as a one-line summary to agents.<role>.inbox
#   - silent when no events; logs to stderr on errors

set -uo pipefail

ROLE="${1:-sun}"
SUBJECT="agents.${ROLE}.inbox"
SINK="${SLACK_EVENTS_SINK:-$HOME/.config/slack-mcp/events.jsonl}"
PIDFILE="/tmp/slack-bridge-${ROLE}.pid"

# singleton via PID file (mkdir would also work; PID file lets us check liveness)
if [ -f "$PIDFILE" ]; then
  old_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "[slack-bridge] already running for role=$ROLE (pid $old_pid)" >&2
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# locate aon — try $AON_BIN, PATH, then known install dirs
_resolve_aon() {
  if [ -n "${AON_BIN:-}" ] && [ -x "$AON_BIN" ]; then echo "$AON_BIN"; return; fi
  if command -v aon >/dev/null 2>&1; then command -v aon; return; fi
  for cand in "$HOME/.local/bin/aon" "$HOME/Repos/ai-over-nats/bin/aon" "/usr/local/bin/aon" "/opt/homebrew/bin/aon"; do
    [ -x "$cand" ] && { echo "$cand"; return; }
  done
}
AON_BIN="$(_resolve_aon)"
if [ -z "$AON_BIN" ]; then
  echo "[slack-bridge] aon not found (PATH=$PATH)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[slack-bridge] jq is required" >&2
  exit 1
fi

# create sink if missing so tail -F doesn't error
mkdir -p "$(dirname "$SINK")"
[ -f "$SINK" ] || touch "$SINK"

echo "[slack-bridge] role=$ROLE subject=$SUBJECT sink=$SINK" >&2

SUSPECT_THRESHOLD="${SLACK_GUARD_THRESHOLD:-0.5}"

tail -F -n 0 "$SINK" 2>/dev/null | while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Build payload: structural delimiters mark this as untrusted DATA, not
  # instructions. injection_score (set by rtm.py if `guard` extra installed)
  # adds a SUSPECT prefix when above threshold.
  text=$(printf '%s' "$line" | jq -r --arg th "$SUSPECT_THRESHOLD" '
    if .type != "message" then empty
    else
      (.injection_score // null) as $s
      | (if ($s != null) and ($s | tonumber) >= ($th | tonumber)
         then "[SUSPECT injection_score=" + ($s | tostring) + "] "
         else "" end) as $flag
      | "📩 " + $flag
        + "[SLACK_INPUT from=\"" + (.user_name // "?")
        + "\" channel=\"" + (.channel_name // "?")
        + "\" kind=\"" + (.channel_kind // "?")
        + "\"]"
        + (.text // "")
        + "[/SLACK_INPUT]"
    end
  ' 2>/dev/null) || continue
  [ -z "$text" ] && continue
  if ! err=$("$AON_BIN" pub "$SUBJECT" "$text" 2>&1 >/dev/null); then
    echo "[slack-bridge] publish failed for '${text:0:80}': $err" >&2
  fi
done
