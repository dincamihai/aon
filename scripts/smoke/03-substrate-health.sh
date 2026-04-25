#!/usr/bin/env bash
# Smoke 03 — substrate health: streams + KV exist with expected shape.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 03 substrate health ──"

# Server reachable from any role
nats_as raj rtt >/dev/null 2>&1 && ok "rtt ok (raj)" || bad "rtt failed (raj)"

# Streams (sysadmin can list)
EXPECTED_STREAMS="TASKS LEARNING RESULTS EVENTS AUDIT"
got_streams=$(nats_as sysadmin stream ls --names 2>/dev/null | sort | xargs)
for s in $EXPECTED_STREAMS; do
  echo "$got_streams" | grep -qw "$s" && ok "stream $s present" || bad "stream $s MISSING"
done

# Stream retention sanity
for s in TASKS LEARNING; do
  info=$(nats_as sysadmin stream info "$s" 2>/dev/null)
  echo "$info" | grep -q "Retention: WorkQueue\|Retention: Workqueue\|Retention: Work" \
    && ok "$s retention=workqueue" || bad "$s retention != workqueue"
done

# KV bucket exists with seeded keys
nats_as sysadmin kv info team-state >/dev/null 2>&1 \
  && ok "kv team-state present" || bad "kv team-state MISSING"
roster=$(nats_as sysadmin kv get team-state team.alpha.roster --raw 2>/dev/null)
echo "$roster" | grep -q '"maya"' && ok "roster seeded with maya" || bad "roster seed missing"

# AUDIT mirrors EVENTS
stream_msg_count() {
  nats_as sysadmin stream info "$1" 2>/dev/null \
    | awk '/^[[:space:]]+Messages:/{gsub(",","",$2); print $2; exit}'
}
events_msgs=$(stream_msg_count EVENTS)
audit_msgs=$(stream_msg_count AUDIT)
if [ -n "$events_msgs" ] && [ -n "$audit_msgs" ] && [ "$audit_msgs" -ge "$events_msgs" ]; then
  ok "AUDIT msgs ≥ EVENTS msgs ($audit_msgs ≥ $events_msgs)"
else
  bad "AUDIT mirror behind EVENTS (audit=$audit_msgs, events=$events_msgs)"
fi

summary
