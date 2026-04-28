#!/usr/bin/env bash
# Sim 12 — preempt cascade: low→med→high, LIFO resume.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 12 preempt cascade (LIFO resume) ──"

LOW="low-$(date +%s%N)"
MED="med-$(date +%s%N)"
HIGH="high-$(date +%s%N)"
TS=$(ts_now)

# Cascade: priya works low → med preempts → high preempts.
kv_put_raw "agent.priya.parked" "[]"
sim_pub board.tasks.terraform.claimed "$(jq -nc --arg s "$LOW"  '{slug:$s, by:"priya"}')"
PARKED="[$(jq -nc --arg s "$LOW" --arg t "$TS" '{slug:$s, since:$t}')]"
kv_put_raw "agent.priya.parked" "$PARKED"
sim_pub board.tasks.terraform.parked  "$(jq -nc --arg s "$LOW"  '{slug:$s, by:"priya"}')"
sim_pub board.tasks.terraform.claimed "$(jq -nc --arg s "$MED"  '{slug:$s, by:"priya"}')"
PARKED="[$(jq -nc --arg s "$LOW" --arg t "$TS" '{slug:$s, since:$t}'),$(jq -nc --arg s "$MED" --arg t "$TS" '{slug:$s, since:$t}')]"
kv_put_raw "agent.priya.parked" "$PARKED"
sim_pub board.tasks.terraform.parked  "$(jq -nc --arg s "$MED"  '{slug:$s, by:"priya"}')"
sim_pub board.tasks.terraform.claimed "$(jq -nc --arg s "$HIGH" '{slug:$s, by:"priya"}')"
ok "claimed cascade low→med→high posted, parked stack=[low,med]"

# Verify KV stack.
val=$(nats --server "$NATS_URL" --creds "$SYSADMIN_CREDS" \
      kv get team-state agent.priya.parked --raw 2>/dev/null)
echo "$val" | jq -e 'length == 2' >/dev/null 2>&1 \
  && ok "parked KV has 2 entries" || bad "parked KV unexpected: $val"
last_slug=$(echo "$val" | jq -r '.[-1].slug')
[ "$last_slug" = "$MED" ] && ok "stack tail = med (LIFO)" || bad "tail=$last_slug expected $MED"

# Resume in LIFO order: high.done → resume med → med.done → resume low.
sim_pub board.tasks.terraform.done    "$(jq -nc --arg s "$HIGH" '{slug:$s, by:"priya"}')"
NEW_PARKED=$(echo "$val" | jq -c '.[:-1]')
kv_put_raw "agent.priya.parked" "$NEW_PARKED"
sim_pub board.tasks.terraform.resumed "$(jq -nc --arg s "$MED"  '{slug:$s, by:"priya"}')" \
  && ok "resumed med (LIFO pop)"

sim_pub board.tasks.terraform.done    "$(jq -nc --arg s "$MED"  '{slug:$s, by:"priya"}')"
kv_put_raw "agent.priya.parked" "[]"
sim_pub board.tasks.terraform.resumed "$(jq -nc --arg s "$LOW"  '{slug:$s, by:"priya"}')" \
  && ok "resumed low (last out)"

val=$(nats --server "$NATS_URL" --creds "$SYSADMIN_CREDS" \
      kv get team-state agent.priya.parked --raw 2>/dev/null)
[ "$val" = "[]" ] && ok "parked KV drained" || bad "parked KV residue: $val"

summary
