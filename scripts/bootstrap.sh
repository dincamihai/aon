#!/usr/bin/env bash
# Bootstrap team-alpha NATS substrate: streams + KV bucket + seed values.
# Idempotent — safe to re-run after upgrades.
#
# Run by: operator (holds sysadmin creds). Not a team role.
# See: docs/onboarding-per-role.md §0.
#
# Required env:
#   NATS_URL              (e.g. nats://localhost:4222)
#   NATS_ADMIN_USER       (default: sysadmin)
#   NATS_ADMIN_PASSWORD   (sysadmin password)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/nats-helpers.sh
source "$REPO_ROOT/scripts/lib/nats-helpers.sh"

command -v "$NATS_BIN" >/dev/null 2>&1 || {
  echo "ERROR: nats CLI not found on PATH (set NATS_BIN to override)" >&2
  exit 1
}

echo "── 1/5 wait for NATS ──"
wait_for_nats 30
echo "  ✓ NATS reachable at $NATS_URL"

echo "── 2/5 streams ──"
# TASKS — production work queue. Workqueue retention: msg deleted on first ack.
ensure_stream TASKS    "board.tasks.>"     work 30d
# LEARNING — growth/stretch work queue.
ensure_stream LEARNING "board.learning.>"  work 30d
# RESULTS — finished work, readable by all. Limits retention.
ensure_stream RESULTS  "board.results.>"   limits    90d
# EVENTS — agent presence, inboxes, broadcasts, state mirror.
# Wide set so AUDIT can source from one stream.
ensure_stream EVENTS   "agents.>,broadcast.>,state.>"  limits 30d

# A2A_TASKS — A2A status/message/cancel subjects (slice 1+2).
# Explicit per-role subjects so it doesn't overlap with `a2a.discovery.>`.
# `a2a.<role>.tasks.send` is intentionally excluded — request-reply
# primitive must NOT be JetStream-stored, otherwise the JS ack races
# with the worker's reply (Maya would receive JS ack instead of worker
# response). Status/message/cancel are deeper subjects (5+ tokens) and
# are the ones we want replayable in AUDIT.
ensure_stream A2A_TASKS \
  "a2a.maya.tasks.*.>,a2a.raj.tasks.*.>,a2a.lin.tasks.*.>,a2a.sam.tasks.*.>,a2a.diego.tasks.*.>,a2a.priya.tasks.*.>" \
  limits 30d

# A2A_DISC — agent card discovery, latest per agent only.
ensure_a2a_disc_stream

# AUDIT — mirrors above streams. No own subjects, sources only.
ensure_audit_stream

echo "── 3/5 KV bucket ──"
# team-state — project state, agent load, skills, roster.
ensure_kv team-state 5 0   # 0 ttl = no expiry per key

echo "── 4/5 seed values ──"
kv_put team-state "team.alpha.roster" '["maya","raj","lin","sam","diego","priya"]'
echo "  + team-state.team.alpha.roster"

if [ -f scripts/seed-skills.json ]; then
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required for seeding skills" >&2; exit 1; }
  for role in maya raj lin sam diego priya; do
    skills=$(jq -c ".\"$role\"" scripts/seed-skills.json)
    kv_put team-state "agent.${role}.skills" "$skills"
    kv_put team-state "agent.${role}.load"   '{"current_tasks":0,"capacity":"idle"}'
    echo "  + team-state.agent.${role}.{skills,load}"
  done
fi

echo "── 5/5 smoke test ──"
SMOKE_PAYLOAD='{"type":"bootstrap-smoke","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
TMP_OUT=$(mktemp)
nats_admin sub broadcast.standup --count 1 --wait 5s > "$TMP_OUT" 2>&1 &
SUB_PID=$!
sleep 1
nats_admin pub broadcast.standup "$SMOKE_PAYLOAD" >/dev/null
wait "$SUB_PID" 2>/dev/null || true
if grep -q "bootstrap-smoke" "$TMP_OUT"; then
  echo "  ✓ pub/sub round-trip OK"
else
  echo "  ✗ pub/sub round-trip FAILED" >&2
  cat "$TMP_OUT" >&2
  rm -f "$TMP_OUT"
  exit 1
fi
rm -f "$TMP_OUT"

echo
echo "✓ team-alpha substrate bootstrapped."
echo "  streams: TASKS LEARNING RESULTS EVENTS AUDIT"
echo "  kv:      team-state"
echo "  seeded:  roster, agent.<role>.{skills,load} for 6 roles"
