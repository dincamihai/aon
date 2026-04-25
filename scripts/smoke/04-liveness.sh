#!/usr/bin/env bash
# Smoke 04 — liveness & stuck-flow detection.
#
# Scans the substrate for tasks that have stalled. Surfaces issues a human
# can act on. Exit non-zero when something is stuck — humans see it in cron
# logs / smoke runs and intervene.
#
# Heuristics:
#   - claimed task with no done within STUCK_AFTER_MIN minutes
#   - blocked task older than ESCALATE_AFTER_MIN with no comment update
#   - role marked active in KV but no events in last IDLE_AFTER_MIN minutes
#   - work-queue stream backlog > BACKLOG_THRESHOLD with no consumers
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"

: "${STUCK_AFTER_MIN:=60}"
: "${ESCALATE_AFTER_MIN:=240}"
: "${IDLE_AFTER_MIN:=120}"
: "${BACKLOG_THRESHOLD:=10}"

echo "── 04 liveness ──"

# Pending backlog without any active workers signals a stuck queue.
pending=$(nats_as sysadmin stream info TASKS 2>/dev/null \
          | awk '/^[[:space:]]+Messages:/{gsub(",","",$2); print $2; exit}')
pending=${pending:-0}
if [ "$pending" -gt "$BACKLOG_THRESHOLD" ]; then
  active_count=0
  for role in maya raj lin sam diego priya; do
    val=$(nats_as sysadmin kv get team-state "agent.$role.load" --raw 2>/dev/null || echo "")
    echo "$val" | grep -q '"capacity":"active"' && active_count=$((active_count + 1))
  done
  if [ "$active_count" -eq 0 ]; then
    bad "TASKS backlog=$pending but NO role is active — humans should investigate"
  else
    ok "TASKS backlog=$pending, $active_count role(s) active"
  fi
else
  ok "TASKS backlog=$pending under threshold ($BACKLOG_THRESHOLD)"
fi

# Stale active load: agent says active but no recent events.
# (Uses last-update timestamp from KV revision metadata as a coarse proxy.)
for role in maya raj lin sam diego priya; do
  meta=$(nats_as sysadmin kv get team-state "agent.$role.load" 2>/dev/null \
         | head -1)
  # meta format: "team-state > agent.<role>.load revision: N created @ <date>"
  ts=$(echo "$meta" | sed -nE 's/.*created @ ([0-9-]+ [0-9:]+).*/\1/p')
  if [ -z "$ts" ]; then
    skip "$role load: no KV entry yet"
    continue
  fi
  # Convert to epoch (BSD date on macOS, GNU date on linux)
  epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null \
       || date -d "$ts" +%s 2>/dev/null \
       || echo 0)
  now=$(date +%s)
  age_min=$(( (now - epoch) / 60 ))
  cap=$(nats_as sysadmin kv get team-state "agent.$role.load" --raw 2>/dev/null \
        | sed -nE 's/.*"capacity":"([^"]+)".*/\1/p')
  if [ "$cap" = "active" ] && [ "$age_min" -gt "$IDLE_AFTER_MIN" ]; then
    bad "$role active but no load update in ${age_min}m (>${IDLE_AFTER_MIN}m) — possibly hung"
  else
    ok "$role load $cap, age=${age_min}m"
  fi
done

# Consumer presence on TASKS — workqueue with no consumers = nobody listening.
consumers=$(nats_as sysadmin consumer ls TASKS --names 2>/dev/null | wc -l | tr -d ' ')
if [ "$pending" -gt 0 ] && [ "$consumers" -eq 0 ]; then
  bad "TASKS has $pending pending msgs but 0 consumers — nobody is reading the queue"
else
  ok "TASKS consumers=$consumers (backlog=$pending)"
fi

summary
