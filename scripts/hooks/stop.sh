#!/usr/bin/env bash
# Stop hook — fires after every assistant turn (NOT per session).
# Side-effects must be turn-safe: no event spam, no duplicate state writes.
# Session-end semantics live in session-end-goodbye.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

TS="$(now_iso)"

# Bump cursor each turn so a session-restart catch-up doesn't replay
# events the agent already saw via the Monitor.
echo -n "$TS" > "$HOOK_CURSOR_FILE" 2>/dev/null || true

# Phase B: idle drill. If post-tool-use dropped a marker (after
# a2a_update_status state=completed), emit a system reminder telling
# the agent to stop hunting for work and trust the Monitor stream.
MARKER="$HOOK_CURSOR_DIR/idle-drill-$HOOK_ROLE.marker"
if [ -f "$MARKER" ]; then
  TASK_ID="$(cat "$MARKER" 2>/dev/null || echo '?')"
  rm -f "$MARKER" 2>/dev/null || true
  CTX="[POST-TASK IDLE DRILL — automatic system reminder]

Task $TASK_ID completed. You are now idle.

DO NOT scan for new work via prompts, DO NOT poll a2a_inbox(), DO NOT
loop on recent_events. Your realtime Monitor subscription will deliver
new dispatch events as notifications. Stay quiet until then or until
the operator gives you a new instruction.

Workers do not pull — the dispatcher (maya) assigns. New tasks arrive
as Monitor notifications matching subject pattern
\`a2a.$HOOK_ROLE.tasks.<id>.send\`. When you see one, call
\`a2a_inbox()\` to pick it up."
  jq -nc --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}' || true
fi

exit 0
