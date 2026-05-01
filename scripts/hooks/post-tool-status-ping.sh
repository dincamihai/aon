#!/usr/bin/env bash
# PostToolUse hook — emit a status ping to `agents.<role>.events`
# after substantive tool actions, so peers (and maya) can observe
# what this agent is up to without asking. Card 212 Phase B.
#
# Rate-limited: max 1 ping per kind per minute per role.
# Side-effect-only. Failures swallowed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // .tool // empty' <<<"$INPUT" 2>/dev/null)
[ -z "$TOOL_NAME" ] && exit 0

NOW=$(date +%s)
TS="$(now_iso)"
LAST_TOOL_FILE="$HOOK_CURSOR_DIR/last-tool-ts-$HOOK_ROLE"
SUBJECT="$(_hook_p "agents.$HOOK_ROLE.events")"

# Rate-limit helper. Returns 0 if the kind hasn't fired in the last
# 60s for this role, 1 otherwise. Updates marker on success.
should_emit() {
  local kind="$1"
  local marker="$HOOK_CURSOR_DIR/ping-$HOOK_ROLE-$kind.last"
  local last=0
  [ -f "$marker" ] && last=$(cat "$marker" 2>/dev/null || echo 0)
  if [ $((NOW - last)) -lt 60 ]; then return 1; fi
  echo -n "$NOW" > "$marker" 2>/dev/null || true
  return 0
}

# Inflight task lookup. Returns first task_id (newest) or empty.
inflight_task_id() {
  local raw
  raw=$(nats_role kv get "$HOOK_KV_BUCKET" "a2a.$HOOK_ROLE.inflight" --raw 2>/dev/null) || return 1
  [ -z "$raw" ] && return 1
  jq -r 'to_entries
         | map(select(.value.state != "completed" and .value.state != "canceled"))
         | sort_by(.value.since // "") | reverse | .[0].key // empty' \
    <<<"$raw" 2>/dev/null
}

# (1) Idle-resume — gap > 30 min between tools.
LAST_TOOL=0
[ -f "$LAST_TOOL_FILE" ] && LAST_TOOL=$(cat "$LAST_TOOL_FILE" 2>/dev/null || echo 0)
GAP=$((NOW - LAST_TOOL))
if [ "$LAST_TOOL" -gt 0 ] && [ "$GAP" -gt 1800 ]; then
  if should_emit resumed; then
    PAYLOAD=$(jq -nc \
      --arg kind resumed --arg role "$HOOK_ROLE" --arg ts "$TS" --argjson gap_s "$GAP" \
      '{kind:$kind, role:$role, gap_s:$gap_s, ts:$ts}')
    hook_pub "$SUBJECT" "$PAYLOAD"
  fi
fi

# (2) Per-tool-name dispatch.
case "$TOOL_NAME" in
  *a2a_update_status*)
    STATE=$(jq -r '.tool_input.state // .params.state // empty' <<<"$INPUT" 2>/dev/null)
    TASK_ID=$(jq -r '.tool_input.task_id // .params.task_id // "?"' <<<"$INPUT" 2>/dev/null)
    [ -n "$STATE" ] || exit 0
    if should_emit "status-$STATE"; then
      PAYLOAD=$(jq -nc \
        --arg kind status --arg role "$HOOK_ROLE" --arg task_id "$TASK_ID" \
        --arg state "$STATE" --arg ts "$TS" \
        '{kind:$kind, role:$role, task_id:$task_id, state:$state, ts:$ts}')
      hook_pub "$SUBJECT" "$PAYLOAD"
    fi
    ;;

  *a2a_send_task*)
    # Manager only — workers shouldn't be calling send_task.
    [ "$HOOK_ROLE" = "sun" ] || [ "$HOOK_ROLE" = "mihai" ] || [ "$HOOK_ROLE" = "mid" ] || exit 0
    TARGET=$(jq -r '.tool_input.role // .tool_input.target // .params.role // empty' <<<"$INPUT" 2>/dev/null)
    SKILL=$(jq -r '.tool_input.skill // .params.skill // empty' <<<"$INPUT" 2>/dev/null)
    TASK_ID=$(jq -r '.tool_input.payload.task_id // .tool_response.task_id // "?"' <<<"$INPUT" 2>/dev/null)
    if should_emit dispatched; then
      PAYLOAD=$(jq -nc \
        --arg kind dispatched --arg role "$HOOK_ROLE" \
        --arg target "$TARGET" --arg skill "$SKILL" \
        --arg task_id "$TASK_ID" --arg ts "$TS" \
        '{kind:$kind, role:$role, target:$target, skill:$skill, task_id:$task_id, ts:$ts}')
      hook_pub "$SUBJECT" "$PAYLOAD"
    fi
    ;;

  *Edit*|*Write*)
    FILE=$(jq -r '.tool_input.file_path // .tool_input.path // .params.file_path // empty' <<<"$INPUT" 2>/dev/null)
    [ -n "$FILE" ] || exit 0
    case "$FILE" in
      "$HOME/Repos/"*) : ;;
      /Users/mid/Repos/*) : ;;
      *) exit 0 ;;
    esac
    TASK_ID=$(inflight_task_id 2>/dev/null || true)
    [ -z "$TASK_ID" ] && exit 0
    if should_emit working; then
      PAYLOAD=$(jq -nc \
        --arg kind working --arg role "$HOOK_ROLE" \
        --arg task_id "$TASK_ID" --arg file "$FILE" --arg ts "$TS" \
        '{kind:$kind, role:$role, task_id:$task_id, file:$file, ts:$ts}')
      hook_pub "$SUBJECT" "$PAYLOAD"
    fi
    ;;
esac

exit 0
