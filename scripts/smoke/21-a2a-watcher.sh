#!/usr/bin/env bash
# Smoke 21 — A2A watcher integration (slice 2 card 133).
#
# Tests three new detections in coordinator-watcher.sh:
#   a2a_stale          — working state >A2A_STALE_SEC
#   a2a_duplicate      — same task_id under two roles' subtrees
#   a2a_orphan_inflight — KV inflight entry stale
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 21 A2A watcher ──"

# Backdated ts: 30 minutes ago (BSD/GNU date compat).
TS_OLD=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)

# ── 1. a2a_stale: priya posted .status=working long ago, no follow-up.
TASK_STALE="t-stale-$(date +%s)"
PAYLOAD_STALE=$(jq -nc --arg id "$TASK_STALE" --arg t "$TS_OLD" \
                '{task_id:$id, state:"working", by:"priya", ts:$t}')
nats_as priya pub "a2a.priya.tasks.$TASK_STALE.status" "$PAYLOAD_STALE" >/dev/null 2>&1 \
  && ok "wrote stale a2a.priya.tasks.$TASK_STALE.status (ts=30m ago)"

# ── 2. a2a_duplicate: same task_id under two roles.
TASK_DUP="t-dup-$(date +%s)"
P1=$(jq -nc --arg id "$TASK_DUP" '{task_id:$id, state:"working", by:"priya", ts:"2026-04-26T12:00:00Z"}')
P2=$(jq -nc --arg id "$TASK_DUP" '{task_id:$id, state:"working", by:"raj",   ts:"2026-04-26T12:00:01Z"}')
nats_as priya pub "a2a.priya.tasks.$TASK_DUP.status" "$P1" >/dev/null 2>&1
nats_as raj   pub "a2a.raj.tasks.$TASK_DUP.status"   "$P2" >/dev/null 2>&1 \
  && ok "wrote duplicate-dispatch events ($TASK_DUP under priya + raj)"

# ── 3. a2a_orphan_inflight: stale KV entry.
TASK_ORPHAN="t-orphan-$(date +%s)"
KV_VAL=$(jq -nc --arg id "$TASK_ORPHAN" --arg t "$TS_OLD" \
         '{($id): {state:"working", since:$t, skill:"terraform", from:"maya"}}')
echo -n "$KV_VAL" | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1 \
  && ok "wrote stale KV inflight ($TASK_ORPHAN, since=30m ago)"

# Wait for AUDIT to pick up status events (mirror lag).
sleep 5

# Run watcher with low thresholds.
ALERTS=$(A2A_STALE_SEC=60 A2A_INFLIGHT_TTL=60 \
         NATS_URL="$NATS_URL" NATS_ADMIN_CREDS="$SYSADMIN_CREDS" \
         WATCHER_LOOKBACK=1h \
         bash "$SMOKE_DIR/../coordinator-watcher.sh" tick 2>&1 | grep '^ALERT:' || true)

if echo "$ALERTS" | grep -q "a2a_stale.*$TASK_STALE"; then
  ok "watcher emitted a2a_stale for $TASK_STALE"
else
  bad "no a2a_stale alert"
  echo "$ALERTS" | head -10 | sed 's/^/    /' >&2
fi

if echo "$ALERTS" | grep -q "a2a_duplicate.*$TASK_DUP"; then
  ok "watcher emitted a2a_duplicate for $TASK_DUP"
else
  bad "no a2a_duplicate alert"
fi

if echo "$ALERTS" | grep -q "a2a_orphan_inflight.*$TASK_ORPHAN"; then
  ok "watcher emitted a2a_orphan_inflight for $TASK_ORPHAN"
else
  bad "no a2a_orphan_inflight alert"
fi

# Cleanup.
echo -n '{}' | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1

summary
