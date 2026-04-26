#!/usr/bin/env bash
# SessionEnd hook — publish goodbye + flip KV human status to "away"
# so dispatcher won't pick this role for new A2A work.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

TS="$(now_iso)"
HOST="$(hostname)"

# Goodbye + session_end events for AUDIT.
EVT=$(jq -nc --arg r "$HOOK_ROLE" --arg h "$HOST" --arg t "$TS" \
  '{type:"goodbye", role:$r, host:$h, timestamp:$t}')
hook_pub "agents.$HOOK_ROLE.events" "$EVT"

# KV human status — dispatcher reads this to skip away workers.
HUMAN=$(jq -nc --arg s "$HOOK_ROLE" --arg t "$TS" --arg r "$HOOK_ROLE" \
  '{slug:$s, by:$r, ts:$t, status:"away", since:$t, reason:"session end"}')
hook_kv_put "agent.$HOOK_ROLE.human" "$HUMAN"

# KV load -> idle (was previously per-turn in stop.sh; now per-session).
LOAD=$(jq -nc --arg h "$HOST" --arg t "$TS" \
  '{current_tasks:0, capacity:"idle", host:$h, since:$t}')
hook_kv_put "agent.$HOOK_ROLE.load" "$LOAD"

exit 0
