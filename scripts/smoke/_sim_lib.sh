#!/usr/bin/env bash
# Sim helpers — used by 08+ scripts that simulate agent workflows.
# Sims publish events directly via nats CLI as the role-acting user. Goal is
# substrate-level validation: did the right events propagate, did watcher
# detect the violation, was audit captured.
set -u

# Source after _lib.sh.
: "${NATS_URL:=nats://localhost:4222}"
# JWT auth: SMOKE_CREDS_DIR is set by _lib.sh; sysadmin .creds lives at
# $SMOKE_CREDS_DIR/sysadmin.creds (run `aon creds --all`).
: "${SMOKE_CREDS_DIR:=$HOME/.aon/teams/${AON_TEAM_NAME:-team-alpha}/creds}"
SYSADMIN_CREDS="$SMOKE_CREDS_DIR/sysadmin.creds"
NATS_BIN="${NATS_BIN:-nats}"

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_nats_sysadmin() {
  "$NATS_BIN" --server "$NATS_URL" --creds "$SYSADMIN_CREDS" "$@"
}

# Publish an agent's event. Use sysadmin to bypass per-role ACL nuances —
# substrate validation is the goal, not ACL enforcement (that's covered by
# 01-auth-boundaries.sh).
sim_pub() {
  local subject="$1" payload="$2"
  _nats_sysadmin pub "$subject" "$payload" >/dev/null 2>&1
}

# Capture state.alert.> for N seconds, return matching alerts.
capture_alerts() {
  local pattern="${1:-state.alert.>}" duration="${2:-3s}"
  _nats_sysadmin sub "$pattern" --wait "$duration" --raw 2>/dev/null
}

# Run watcher tick once (heavy on large AUDIT — sims should prefer
# audit_query_slug below for targeted assertions).
watcher_tick() {
  NATS_URL="$NATS_URL" NATS_ADMIN_CREDS="$SYSADMIN_CREDS" \
    bash "$(dirname "$BASH_SOURCE")/../coordinator-watcher.sh" tick 2>&1
}

# Pull AUDIT messages matching subject pattern containing slug. Returns
# distinct .by values (one per role that emitted). Fast: targeted ephemeral
# pull consumer.
audit_distinct_emitters() {
  local subject="$1" slug="$2"
  local since="${3:-60s}"
  local cname="sim-$$-$(date +%s%N)-$RANDOM"
  _nats_sysadmin consumer add AUDIT "$cname" \
    --filter "$subject" --pull --deliver "$since" --ack=none \
    --replay=instant --ephemeral --defaults >/dev/null 2>&1 || { echo ""; return; }
  _nats_sysadmin consumer next AUDIT "$cname" --count 500 --raw --wait 1s 2>/dev/null \
    | jq -r --arg s "$slug" 'select(.slug == $s) | (.by // .role // .from // "?")' 2>/dev/null \
    | sort -u
  _nats_sysadmin consumer rm AUDIT "$cname" -f >/dev/null 2>&1 || true
}

# KV write helper (sysadmin path).
kv_put_raw() {
  local key="$1" value="$2"
  echo -n "$value" | _nats_sysadmin kv put team-state "$key" >/dev/null 2>&1
}
