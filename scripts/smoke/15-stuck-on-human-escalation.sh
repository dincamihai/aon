#!/usr/bin/env bash
# Sim 15 — agent stuck waiting on busy human; escalation chain.
# Sequence: agent posts ASK → peer doesn't reply → agent escalates to maya
# → emits state.alert.no_human.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 15 stuck-on-human escalation ──"

# Lin's human is busy; Lin tries to claim a python task but needs guidance.
kv_put_raw "agent.lin.human" '{"status":"busy"}'

# 1. Lin posts an ASK to raj's inbox (peer first).
sim_pub agents.raj.inbox \
  '{"type":"ask","from":"lin","topic":"python schema unclear","slug":"task-x","ts":"'"$(ts_now)"'"}' \
  && ok "lin posted ask to raj inbox"

# (Sim assumes raj doesn't reply within escalation window.)
sleep 0.5

# 2. Lin escalates to maya.
sim_pub agents.maya.inbox \
  '{"type":"escalation","from":"lin","reason":"raj timeout, my human busy","topic":"python schema","ts":"'"$(ts_now)"'"}' \
  && ok "lin escalated to maya"

# 3. Lin emits state.alert.no_human (last-resort signal).
NO_HUMAN_TS=$(ts_now)
sim_pub state.alert.no_human \
  "$(jq -nc --arg t "$NO_HUMAN_TS" '{from:"lin", reason:"escalation unresolved", ts:$t}')" \
  && ok "lin emitted state.alert.no_human"

# 4. Verify alert observable.
sleep 0.5
ALERTS=$(mktemp)
capture_alerts 'state.alert.no_human' 2s > "$ALERTS" 2>/dev/null
if grep -q '"from":"lin"' "$ALERTS" 2>/dev/null; then
  ok "alert state.alert.no_human visible to subscribers"
else
  # Stream-replay fallback (capture_alerts uses live sub; alert may have been emitted before).
  STREAM_HIT=$(nats --server "$NATS_URL" --creds "$SYSADMIN_CREDS" \
    sub 'state.alert.no_human' --since 30s --count 5 --raw --wait 2s 2>/dev/null \
    | grep -c '"from":"lin"')
  [ "${STREAM_HIT:-0}" -ge 1 ] \
    && ok "alert visible via stream replay (count=$STREAM_HIT)" \
    || bad "no_human alert not observed live or in stream"
fi
rm -f "$ALERTS"

# Restore.
kv_put_raw "agent.lin.human" '{"status":"available"}'

summary
