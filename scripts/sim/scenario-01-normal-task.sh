#!/usr/bin/env bash
# Scenario 01 — normal task: Maya posts terraform task, Priya claims+ships.
# Validates: ACL allows full chain; AUDIT records each step; KV not polluted.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 01: normal task (maya → priya) ──"

TID=$(maya_post_task terraform medium "add staging VPC peering")
[ -n "$TID" ] && ok "maya posted task $TID" || bad "maya post empty"

worker_claim_and_ship priya terraform "$TID" sha-priya-1 \
  && ok "priya claimed + shipped $TID"

sleep 1

# AUDIT must show one pending + one claimed + one done + one shipped, all
# with same slug.
events=$(audit_events_for_slug 'board.>' "$TID")
got_count=$(echo "$events" | grep -c '^.' || true)
[ "$got_count" -eq 4 ] \
  && ok "AUDIT records 4 events (pending+claimed+done+shipped) for $TID" \
  || bad "AUDIT has $got_count events for $TID (expected 4)"

# Single claimer = priya
claimers=$(audit_events_for_slug 'board.tasks.*.claimed' "$TID" \
           | jq -r '.by' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
[ "$claimers" = "priya" ] && ok "single claimer = priya" \
  || bad "expected single claimer 'priya', got '$claimers'"

# Single shipper = priya
shippers=$(audit_events_for_slug 'board.results.>' "$TID" \
           | jq -r '.by' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
[ "$shippers" = "priya" ] && ok "single shipper = priya" \
  || bad "expected single shipper 'priya', got '$shippers'"

summary
