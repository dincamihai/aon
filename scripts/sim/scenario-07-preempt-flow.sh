#!/usr/bin/env bash
# Scenario 07 — full preempt flow: Maya bumps priority on Priya mid-flight,
# Priya parks low, switches to high, ships high, resumes low, ships low.
#
# Validates substrate: parked KV stack mutates correctly, parked + resumed
# events fire in order, AUDIT trail tells the full story.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 07: preempt + park + resume (maya, priya) ──"

LOW="low-$(date +%s%N)"
HIGH="high-$(date +%s%N)"

# 1. Maya posts low-priority terraform task; Priya claims and starts.
maya_post=$(jq -nc --arg s "$LOW" --arg t "$(ts_now)" \
  '{task_id:$s, slug:$s, summary:"vacuum old VPC peerings", priority:"low",
    ts:$t, by:"maya"}')
as_role maya pub board.tasks.terraform.pending "$maya_post" >/dev/null 2>&1 \
  && ok "maya posted low ($LOW)"

priya_claim=$(jq -nc --arg s "$LOW" --arg t "$(ts_now)" '{slug:$s, by:"priya", ts:$t}')
as_role priya pub board.tasks.terraform.claimed "$priya_claim" >/dev/null 2>&1 \
  && ok "priya claimed low"

# Priya makes some progress (proxy event).
prog=$(jq -nc --arg s "$LOW" --arg t "$(ts_now)" \
  '{slug:$s, by:"priya", ts:$t, note:"first 2 peerings cleaned"}')
as_role priya pub board.tasks.terraform.progress "$prog" >/dev/null 2>&1 \
  && ok "priya progress on low"

# 2. Maya posts high-priority preempting low.
maya_high=$(jq -nc --arg h "$HIGH" --arg l "$LOW" --arg t "$(ts_now)" \
  '{task_id:$h, slug:$h, summary:"prod-VPC IAM rotation",
    priority:"high", ts:$t, by:"maya", preempts:$l}')
as_role maya pub board.tasks.terraform.pending "$maya_high" >/dev/null 2>&1 \
  && ok "maya posted high preempting low"

# 3. Priya parks low: commit wip marker, append KV stack, emit parked event.
PARKED_STACK=$(jq -nc --arg s "$LOW" --arg t "$(ts_now)" \
  --arg b "feature/$LOW" '[{slug:$s, branch:$b, since:$t}]')
echo -n "$PARKED_STACK" | as_role priya kv put team-state agent.priya.parked >/dev/null \
  && ok "priya parked low to KV stack"
parked_evt=$(jq -nc --arg s "$LOW" --arg t "$(ts_now)" \
  '{slug:$s, by:"priya", ts:$t, reason:"preempt", branch:"feature/'"$LOW"'"}')
as_role priya pub state.agent.priya.parked "$parked_evt" >/dev/null 2>&1 \
  && ok "priya emitted parked event"

# 4. Priya claims high, finishes, ships.
priya_high=$(jq -nc --arg s "$HIGH" --arg t "$(ts_now)" '{slug:$s, by:"priya", ts:$t}')
as_role priya pub board.tasks.terraform.claimed "$priya_high" >/dev/null 2>&1 \
  && ok "priya claimed high"
worker_claim_and_ship priya terraform "$HIGH" sha-priya-high >/dev/null 2>&1
done_high=$(jq -nc --arg s "$HIGH" --arg t "$(ts_now)" '{slug:$s, by:"priya", ts:$t}')
as_role priya pub board.tasks.terraform.done "$done_high" >/dev/null 2>&1 \
  && ok "priya completed high"

# 5. Priya resumes low: pop KV stack, emit resumed event, continue.
echo -n '[]' | as_role priya kv put team-state agent.priya.parked >/dev/null \
  && ok "priya emptied parked KV (popped low)"
resumed_evt=$(jq -nc --arg s "$LOW" --arg t "$(ts_now)" \
  '{slug:$s, by:"priya", ts:$t, from_park:true}')
as_role priya pub state.agent.priya.resumed "$resumed_evt" >/dev/null 2>&1 \
  && ok "priya emitted resumed event for low"

# 6. Priya ships low.
worker_claim_and_ship priya terraform "$LOW" sha-priya-low >/dev/null 2>&1
ok "priya completed low (after resume)"

sleep 1

# Assertions
events_low=$(audit_events_for_slug 'board.>' "$LOW" | grep -c '^.')
[ "$events_low" -ge 4 ] && ok "AUDIT: ≥4 events for low ($events_low)" \
  || bad "expected ≥4 low events, got $events_low"

events_high=$(audit_events_for_slug 'board.>' "$HIGH" | grep -c '^.')
[ "$events_high" -ge 3 ] && ok "AUDIT: ≥3 events for high ($events_high)" \
  || bad "expected ≥3 high events, got $events_high"

parked_seen=$(audit_events_for_slug 'state.agent.priya.parked' "$LOW" | grep -c '^.')
[ "$parked_seen" -ge 1 ] && ok "AUDIT shows priya parked low" \
  || bad "no parked event in audit"

resumed_seen=$(audit_events_for_slug 'state.agent.priya.resumed' "$LOW" | grep -c '^.')
[ "$resumed_seen" -ge 1 ] && ok "AUDIT shows priya resumed low" \
  || bad "no resumed event in audit"

# KV stack empty at end
final_stack=$(as_role sysadmin kv get team-state agent.priya.parked --raw 2>/dev/null)
[ "$final_stack" = "[]" ] && ok "final parked KV = []" \
  || bad "expected empty parked stack, got: $final_stack"

summary
