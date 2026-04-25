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

exit 0
