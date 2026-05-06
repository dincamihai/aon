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

# Subjects include the role qualifier so per-role NATS publish/subscribe
# allow rules can target their own namespace (workers/specialists pub
# only on their own gate-request.@ROLE@.>; sub only on their own
# gate-reply.@ROLE@.>). sysadmin sees the wildcard.
subject_req="evt.coord-in.gate-request.$role.$req_id"
subject_rep="evt.coord-out.gate-reply.$role.$req_id"

# Subscribe first (background) so we don't miss the reply; nats --count=1
# returns when one msg arrives.
# Deterministic path — cleanup is caller's responsibility.
tmp="/tmp/gate-reply.$role.$req_id"
trap 'rm -f "$tmp"; kill $sub_pid 2>/dev/null; exit' EXIT INT TERM

nats --server "$url" --creds "$creds" sub --count=1 --raw \
  "$subject_rep" >"$tmp" 2>/dev/null &
sub_pid=$!

# Reliable sub-registration wait: poll PID existence with short backoff.
# No arbitrary sleep — sub is ready as soon as process stays alive past
# the NATS handshake window (~5ms local, ~50ms remote).
sub_ready=0
for _ in 1 2 3 4 5; do
  if kill -0 "$sub_pid" 2>/dev/null; then
    sub_ready=1
    break
  fi
  sleep 0.01
done
[ "$sub_ready" = 1 ] || exit 1

# Publish request
nats --server "$url" --creds "$creds" pub \
  "$subject_req" "$req" >/dev/null 2>&1 || {
    kill $sub_pid 2>/dev/null
    exit 1
  }

# Log req_id → reply subject mapping before waiting
gate_log INFO "operator-ask: $req_id → $subject_rep"

# Wait for reply — no timeout (GATE_ASK_TIMEOUT = 0 = forever).
# Only use timeout wrapper if explicitly set > 0.
if [[ ${GATE_ASK_TIMEOUT:-0} -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
  # Shell `wait` is a builtin; run in background subshell so `timeout` can
  # kill the wait wrapper rather than the NATS subscriber.
  timeout "$GATE_ASK_TIMEOUT" bash -c 'wait "$1"' _ "$sub_pid" 2>/dev/null || {
    kill "$sub_pid" 2>/dev/null
    gate_log WARN "operator-ask timeout for $req_id"
    exit 1
  }
else
  wait "$sub_pid"
fi

reply=$(cat "$tmp")
[ -n "$reply" ] || exit 1

# Validate shape
decision=$(printf '%s' "$reply" | jq -er '.decision' 2>/dev/null) || exit 1
operator=$(printf '%s' "$reply" | jq -r '.operator // "?"' 2>/dev/null)
gate_log INFO "operator-ask: $req_id decision=$decision operator=$operator"
case "$decision" in
  allow|deny) printf '%s\n' "$reply" ;;
  *) exit 1 ;;
esac
