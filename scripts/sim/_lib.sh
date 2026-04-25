#!/usr/bin/env bash
# Sim helpers — full-chain scenarios where each "agent" is a bash function
# enacting that role's protocol against the live substrate.
set -u

: "${NATS_URL:=nats://localhost:4222}"
: "${SIM_PASS:=devpass}"
NATS_BIN="${NATS_BIN:-nats}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Each role acts via its own NATS user. Ensures ACL is exercised.
as_role() {
  local role="$1"; shift
  "$NATS_BIN" --server "$NATS_URL" --user "$role" --password "$SIM_PASS" "$@"
}

# Maya posts a pending task. Returns task_id on stdout.
maya_post_task() {
  local domain="$1" priority="$2" summary="$3"
  local tid="t-$(date +%s%N)-$RANDOM"
  local payload
  payload=$(jq -nc --arg id "$tid" --arg s "$summary" --arg p "$priority" --arg t "$(ts_now)" \
    '{task_id:$id, slug:$id, summary:$s, priority:$p, ts:$t, by:"maya"}')
  as_role maya pub "board.tasks.$domain.pending" "$payload" >/dev/null 2>&1
  echo "$tid"
}

# Specialist/generalist claims + ships a task. Idempotent in protocol terms.
worker_claim_and_ship() {
  local role="$1" domain="$2" tid="$3" sha="${4:-deadbeef}"
  local now; now=$(ts_now)
  local claim done shipped
  claim=$(jq -nc --arg s "$tid" --arg by "$role" --arg t "$now" '{slug:$s, by:$by, ts:$t}')
  as_role "$role" pub "board.tasks.$domain.claimed" "$claim" >/dev/null 2>&1 \
    || { bad "$role claim publish failed (perm?)"; return 1; }
  done=$(jq -nc --arg s "$tid" --arg by "$role" --arg t "$now" '{slug:$s, by:$by, ts:$t}')
  as_role "$role" pub "board.tasks.$domain.done" "$done" >/dev/null 2>&1 \
    || { bad "$role done publish failed"; return 1; }
  shipped=$(jq -nc --arg s "$tid" --arg by "$role" --arg t "$now" --arg sha "$sha" \
    '{slug:$s, by:$by, ts:$t, sha:$sha}')
  as_role "$role" pub "board.results.$domain.shipped" "$shipped" >/dev/null 2>&1 \
    || { bad "$role results publish failed"; return 1; }
  return 0
}

# Pull events for a slug from AUDIT, filtered by subject pattern.
# Uses --deliver=<duration> to bound replay window — avoids scanning entire
# AUDIT history (which grows across runs and otherwise drowns recent events).
audit_events_for_slug() {
  local subject_pattern="$1" slug="$2"
  local since="${3:-60s}"
  local cname="sim-$$-$(date +%s%N)-$RANDOM"
  as_role sysadmin consumer add AUDIT "$cname" \
    --filter "$subject_pattern" --pull --deliver "$since" --ack=none \
    --replay=instant --ephemeral --defaults >/dev/null 2>&1 || { echo ""; return; }
  as_role sysadmin consumer next AUDIT "$cname" --count 500 --raw --wait 1s 2>/dev/null \
    | jq -c --arg s "$slug" 'select(.slug == $s)' 2>/dev/null
  as_role sysadmin consumer rm AUDIT "$cname" -f >/dev/null 2>&1 || true
}

# DM via inbox + capture immediate reply. Used for incident pairing.
dm_to_inbox() {
  local from_role="$1" peer="$2" payload="$3"
  as_role "$from_role" pub "agents.$peer.inbox" "$payload" >/dev/null 2>&1
}

# Read KV key.
kv_read() {
  as_role sysadmin kv get team-state "$1" --raw 2>/dev/null
}

summary() {
  echo
  printf 'Scenario: \033[32m%d pass\033[0m, \033[31m%d fail\033[0m\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
