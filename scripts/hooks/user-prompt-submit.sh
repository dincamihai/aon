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

IDLE_MARKER="$HOOK_CURSOR_DIR/idle-drill-$HOOK_ROLE.marker"
REFRESH_MARKER="$HOOK_CURSOR_DIR/refresh-role-$HOOK_ROLE.marker"

CTX=""

# Idle drill block.
if [ -f "$IDLE_MARKER" ]; then
  TASK_ID="$(cat "$IDLE_MARKER" 2>/dev/null || echo '?')"
  rm -f "$IDLE_MARKER" 2>/dev/null || true
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
fi

# Role-brief refresh block (Card 212 Phase A).
if [ -f "$REFRESH_MARKER" ]; then
  TRIGGER="$(cat "$REFRESH_MARKER" 2>/dev/null || echo '?')"
  rm -f "$REFRESH_MARKER" 2>/dev/null || true
  REFRESH="[ROLE BRIEF REFRESH — automatic system reminder]

You've been working for a while (trigger: $TRIGGER). Re-anchor on
your role before continuing:

- You are $HOOK_ROLE. Role brief: agent-prompts/$HOOK_ROLE.md
- Stay in role. Do not drift to generic Claude defaults.
- After /clear or compaction: call get_role_brief() to reload identity.
- Past decisions lost? Use /find-transcript to recover context.

Resume current work after the re-anchor."
  if [ -n "$CTX" ]; then
    CTX="$CTX

$REFRESH"
  else
    CTX="$REFRESH"
  fi
fi

[ -z "$CTX" ] && exit 0

jq -nc --arg ctx "$CTX" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'

exit 0
