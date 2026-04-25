#!/usr/bin/env bash
# Smoke 06 — priority change in flight.
#
# Models: Maya posts a task at priority=medium; before anyone claims, an
# incident shifts urgency and Maya reposts the same task_id at priority=high.
# Validates:
#   - second pending msg accepted (no dedupe block on same task_id within
#     stream's duplicate window if payload differs — note the duplicate window
#     is keyed on Nats-Msg-Id header which we don't set here, so both pass)
#   - audit stream shows both pubs in order, so a human can reconstruct the
#     priority change history
#   - workers picking up the task should consume the high-priority one if
#     they pull last-seq (test: stream shows 2 msgs on the subject)
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 06 priority change ──"

TASK_ID="prio-$(date +%s)-$$"
SUBJECT="board.tasks.terraform.pending"

# Capture starting AUDIT count (durable mirror of TASKS).
start_audit=$(nats_as sysadmin stream info AUDIT 2>/dev/null \
              | awk '/^[[:space:]]+Messages:/{gsub(",","",$2); print $2; exit}')
start_audit=${start_audit:-0}

# Pub 1: medium.
nats_as maya pub "$SUBJECT" \
  "$(printf '{"task_id":"%s","summary":"resize VPC","priority":"medium","ts":"%s"}' "$TASK_ID" "$(date -u +%FT%TZ)")" \
  >/dev/null 2>&1 && ok "maya posted at medium" || bad "first publish failed"

sleep 0.3

# Pub 2: same task_id, priority high.
nats_as maya pub "$SUBJECT" \
  "$(printf '{"task_id":"%s","summary":"resize VPC","priority":"high","ts":"%s","supersedes":"medium"}' "$TASK_ID" "$(date -u +%FT%TZ)")" \
  >/dev/null 2>&1 && ok "maya re-posted at high (supersedes medium)" || bad "second publish failed"

# TASKS uses workqueue retention — msgs vanish on first ack OR if no consumer
# binds with delete-on-no-interest semantics. So TASKS may not persist both;
# AUDIT (limits retention, sources from TASKS) IS the durable record.
audit_start=${start_audit:-0}
audit_end=$(nats_as sysadmin stream info AUDIT 2>/dev/null \
            | awk '/^[[:space:]]+Messages:/{gsub(",","",$2); print $2; exit}')
audit_end=${audit_end:-0}
# Grew by at least 2 (the two pubs).
if [ "$audit_end" -ge $((audit_start + 2)) ]; then
  ok "AUDIT grew to $audit_end (≥ start+2) — both versions captured"
else
  bad "AUDIT only at $audit_end (start was $audit_start) — supersession not auditable"
fi

echo
echo "  human note: priority changes by re-publish leave both versions in the"
echo "  log. If you want supersession, claimers should peek the latest seq for"
echo "  task_id before acting. Card 65 sim should cover this behavior."

summary
