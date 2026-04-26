#!/usr/bin/env bash
# Stop hook — flip KV load=idle, publish session_end event.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

TS="$(now_iso)"
HOST="$(hostname)"

LOAD=$(jq -nc --arg h "$HOST" --arg t "$TS" \
  '{current_tasks:0, capacity:"idle", host:$h, since:$t}')
hook_kv_put "agent.$HOOK_ROLE.load" "$LOAD"

EVT=$(jq -nc --arg r "$HOOK_ROLE" --arg h "$HOST" --arg t "$TS" \
  '{type:"session_end", role:$r, host:$h, timestamp:$t}')
hook_pub "agents.$HOOK_ROLE.events" "$EVT"

# Bump cursor on clean exit so next session catch-up starts here.
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
