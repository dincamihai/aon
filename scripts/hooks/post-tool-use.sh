#!/usr/bin/env bash
# PostToolUse hook — detect a2a_update_status(state="completed") call,
# drop a marker file so the Stop hook can emit the idle drill.
#
# Side-effect-only. PostToolUse stdout does NOT reach the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

# Stdin: JSON event for the tool call. Look for tool_name + tool_input.
INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // .tool // empty' <<<"$INPUT" 2>/dev/null)
[ -z "$TOOL_NAME" ] && exit 0

# Only act on a2a_update_status calls.
case "$TOOL_NAME" in
  *a2a_update_status*) : ;;
  *) exit 0 ;;
esac

STATE=$(jq -r '.tool_input.state // .params.state // empty' <<<"$INPUT" 2>/dev/null)
[ "$STATE" = "completed" ] || exit 0

TASK_ID=$(jq -r '.tool_input.task_id // .params.task_id // "?"' <<<"$INPUT" 2>/dev/null)

# Drop marker for stop.sh to pick up.
MARKER="$HOOK_CURSOR_DIR/idle-drill-$HOOK_ROLE.marker"
echo "$TASK_ID" > "$MARKER" 2>/dev/null || true

exit 0
