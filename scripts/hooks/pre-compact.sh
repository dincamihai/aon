#!/usr/bin/env bash
# PreCompact hook — publish a recap_request event so peers / coord
# know this role's context window is about to be compacted (state may
# be lossy after).
#
# Future: a coord agent listens for recap_request and replies with a
# steering message via agents.<role>.inbox. For now we just emit the
# event so AUDIT captures the boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

TS="$(now_iso)"
HOST="$(hostname)"

EVT=$(jq -nc --arg r "$HOOK_ROLE" --arg h "$HOST" --arg t "$TS" \
  '{type:"recap_request", role:$r, host:$h, timestamp:$t,
    source:"compact", reason:"context window compacting"}')
hook_pub "agents.$HOOK_ROLE.events" "$EVT"

exit 0
