#!/usr/bin/env bash
# Block the gate awaiting operator approval over NATS request/reply.
# Usage:
#   operator-ask.sh <argv> <category> <reason>
# Stdin: nothing.
# Stdout: JSON {decision:"allow"|"deny",operator,reason} on success.
# Exit 0 on any decision (allow or deny). Exit 1 on infra failure
# (caller should treat as $GATE_FALLBACK).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/_lib.sh"

argv="${1:-}"; category="${2:-}"; reason="${3:-}"
role="${AON_ROLE:-unknown}"
team="${AON_TEAM:-team-alpha}"
url="${AON_NATS_URL:-}"
creds="${AON_CREDS:-}"

[ -n "$url" ] && [ -n "$creds" ] && command -v nats >/dev/null 2>&1 || exit 1

# Generate request id (uuid-ish) — ts + pid + rand.
req_id="$(date +%s)-$$-$RANDOM"
cwd="${PWD:-?}"

req=$(jq -nc \
  --arg id "$req_id" --arg role "$role" --arg argv "$argv" \
  --arg cat "$category" --arg reason "$reason" --arg cwd "$cwd" \
  '{id:$id, role:$role, argv:$argv, category:$cat,
    reason:$reason, cwd:$cwd}')

subject_req="evt.coord-in.gate-request.$req_id"
subject_rep="evt.coord-out.gate-reply.$req_id"

# Subscribe first (background) so we don't miss the reply; nats --count=1
# returns when one msg arrives.
tmp=$(mktemp -t gate-reply.XXXXXX)
trap 'rm -f "$tmp"' EXIT

nats --server "$url" --creds "$creds" sub --count=1 --raw \
  "$subject_rep" >"$tmp" 2>/dev/null &
sub_pid=$!

# Tiny grace period for sub to attach
sleep 0.2

# Publish request
nats --server "$url" --creds "$creds" pub \
  "$subject_req" "$req" >/dev/null 2>&1 || {
    kill $sub_pid 2>/dev/null
    exit 1
  }

# Wait for reply with timeout
deadline=$(( $(date +%s) + GATE_ASK_TIMEOUT ))
while kill -0 $sub_pid 2>/dev/null; do
  [ "$(date +%s)" -ge "$deadline" ] && {
    kill $sub_pid 2>/dev/null
    gate_log WARN "operator-ask timeout for $req_id"
    exit 1
  }
  sleep 0.5
done

reply=$(cat "$tmp")
[ -n "$reply" ] || exit 1

# Validate shape
decision=$(printf '%s' "$reply" | jq -er '.decision' 2>/dev/null) || exit 1
case "$decision" in
  allow|deny) printf '%s\n' "$reply" ;;
  *) exit 1 ;;
esac
