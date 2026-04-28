#!/usr/bin/env bash
# Sim 11 — preempt: park low-prio, switch to high, resume low.
# Validates substrate captures park/resume events and KV state list grows/shrinks.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 11 preempt park-resume ──"

LOW="low-$(date +%s%N)"
HIGH="high-$(date +%s%N)"
TS=$(ts_now)

# 1. Maya posts low.
sim_pub board.tasks.terraform.pending \
  "$(jq -nc --arg s "$LOW" '{task_id:$s, summary:"low", priority:"low"}')"

# 2. Priya claims low.
sim_pub board.tasks.terraform.claimed \
  "$(jq -nc --arg s "$LOW" --arg t "$TS" '{slug:$s, by:"priya", ts:$t}')" \
  && ok "priya claimed low ($LOW)"

# 3. Maya posts high preempting low.
sim_pub board.tasks.terraform.pending \
  "$(jq -nc --arg h "$HIGH" --arg l "$LOW" \
     '{task_id:$h, summary:"high", priority:"high", preempts:$l}')" \
  && ok "maya posted high preempting low"

# 4. Priya parks low + claims high (sim emulates agent decision).
PARKED_LIST="[$(jq -nc --arg s "$LOW" --arg t "$TS" --arg b "feature/$LOW" \
                '{slug:$s, branch:$b, since:$t}')]"
kv_put_raw "agent.priya.parked" "$PARKED_LIST" \
  && ok "priya parked KV state"
sim_pub board.tasks.terraform.parked \
  "$(jq -nc --arg s "$LOW" --arg t "$TS" '{slug:$s, by:"priya", ts:$t, reason:"preempt"}')" \
  && ok "priya emitted parked event"
sim_pub board.tasks.terraform.claimed \
  "$(jq -nc --arg s "$HIGH" --arg t "$TS" '{slug:$s, by:"priya", ts:$t}')" \
  && ok "priya claimed high"

# 5. Priya finishes high.
sim_pub board.tasks.terraform.done \
  "$(jq -nc --arg s "$HIGH" --arg t "$TS" '{slug:$s, by:"priya", ts:$t}')" \
  && ok "priya finished high"

# 6. Priya resumes low: empty parked, emit resumed.
kv_put_raw "agent.priya.parked" "[]"
sim_pub board.tasks.terraform.resumed \
  "$(jq -nc --arg s "$LOW" --arg t "$TS" '{slug:$s, by:"priya", ts:$t}')" \
  && ok "priya emitted resumed for low"

# Verify KV is empty list.
val=$(nats --server "$NATS_URL" --creds "$SYSADMIN_CREDS" \
      kv get team-state agent.priya.parked --raw 2>/dev/null)
[ "$val" = "[]" ] && ok "priya parked KV emptied" || bad "priya parked KV: $val"

summary
