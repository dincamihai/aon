#!/usr/bin/env bash
# PostToolUse hook — drop a "role brief refresh" marker file when
# the agent has been running long enough that the role rules may
# have drifted out of working context. UserPromptSubmit reads the
# marker on the next operator turn and injects a system reminder.
#
# Side-effect-only. PostToolUse stdout does NOT reach the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // .tool // empty' <<<"$INPUT" 2>/dev/null)
[ -z "$TOOL_NAME" ] && exit 0

NOW=$(date +%s)
COUNT_FILE="$HOOK_CURSOR_DIR/tool-count-$HOOK_ROLE"
LAST_TOOL_FILE="$HOOK_CURSOR_DIR/last-tool-ts-$HOOK_ROLE"
LAST_REFRESH_FILE="$HOOK_CURSOR_DIR/last-refresh-$HOOK_ROLE"
MARKER="$HOOK_CURSOR_DIR/refresh-role-$HOOK_ROLE.marker"

# Bump tool counter.
COUNT=0
[ -f "$COUNT_FILE" ] && COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo -n "$COUNT" > "$COUNT_FILE" 2>/dev/null || true

# Compute gap since previous tool.
LAST_TOOL=0
[ -f "$LAST_TOOL_FILE" ] && LAST_TOOL=$(cat "$LAST_TOOL_FILE" 2>/dev/null || echo 0)
GAP=$((NOW - LAST_TOOL))
echo -n "$NOW" > "$LAST_TOOL_FILE" 2>/dev/null || true

# Already-fresh? (< 30 min since last refresh) → no-op.
LAST_REFRESH=0
[ -f "$LAST_REFRESH_FILE" ] && LAST_REFRESH=$(cat "$LAST_REFRESH_FILE" 2>/dev/null || echo 0)
if [ $((NOW - LAST_REFRESH)) -lt 1800 ]; then exit 0; fi

# Trigger conditions.
TRIGGER=""

# (1) tool count over threshold since last refresh
if [ "$COUNT" -gt 25 ]; then TRIGGER="tool-count>25"; fi

# (2) Edit/Write/Bash after 10+ minute idle gap (suggests fresh start)
if [ -z "$TRIGGER" ]; then
  case "$TOOL_NAME" in
    *Edit*|*Write*|*Bash*)
      [ "$GAP" -gt 600 ] && TRIGGER="resumed-edit-after-${GAP}s"
      ;;
  esac
fi

# (3) High-stakes A2A action
if [ -z "$TRIGGER" ]; then
  case "$TOOL_NAME" in
    *a2a_send_task*|*a2a_update_status*|*dm*) TRIGGER="a2a-action:$TOOL_NAME" ;;
  esac
fi

[ -z "$TRIGGER" ] && exit 0

# Drop marker for user-prompt-submit.sh; reset counter.
echo -n "$TRIGGER" > "$MARKER" 2>/dev/null || true
echo -n "$NOW" > "$LAST_REFRESH_FILE" 2>/dev/null || true
echo -n 0 > "$COUNT_FILE" 2>/dev/null || true

exit 0
