#!/usr/bin/env bash
# UserPromptSubmit hook — inject pending system reminders into the
# next user-turn context. Idle drill (defect 207 follow-up) is
# delivered here because Stop hook schema doesn't accept
# additionalContext.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

MARKER="$HOOK_CURSOR_DIR/idle-drill-$HOOK_ROLE.marker"
[ -f "$MARKER" ] || exit 0

TASK_ID="$(cat "$MARKER" 2>/dev/null || echo '?')"
rm -f "$MARKER" 2>/dev/null || true

CTX="[POST-TASK IDLE DRILL — automatic system reminder]

Task $TASK_ID completed previously. You are idle.

DO NOT scan for new work via prompts, DO NOT poll a2a_inbox(), DO NOT
loop on recent_events. Your realtime Monitor subscription will deliver
new dispatch events as notifications. Stay quiet until then or until
the operator gives you a new instruction.

Workers do not pull — the dispatcher (maya) assigns. New tasks arrive
as Monitor notifications matching subject pattern
\`a2a.$HOOK_ROLE.tasks.<id>.send\`. When you see one, call
\`a2a_inbox()\` to pick it up."

jq -nc --arg ctx "$CTX" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'

exit 0
