#!/usr/bin/env bash
# Scenario 06 — ASK chain discipline (card 95): no flooding humans.
#
# Lin's human is busy. Lin needs unblocking. Correct behavior:
#   1. DM peer (raj) ONCE.
#   2. After timeout, DM coordinator (maya) ONCE.
#   3. Emit state.alert.no_human ONCE.
#   4. STOP. No further DMs.
#
# This sim publishes the canonical sequence and asserts AUDIT shows exactly
# that — not 5 retries to raj, not a flood.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 06: ASK chain discipline (no human flood) ──"

ASK_ID="ask-$(date +%s%N)"

# Lin sets human=busy.
echo -n '{"status":"busy","since":"'"$(ts_now)"'"}' \
  | as_role sysadmin kv put team-state agent.lin.human >/dev/null
ok "lin.human=busy"

# Step 1: lin DMs raj once.
ask_raj=$(jq -nc --arg s "$ASK_ID" --arg t "$(ts_now)" \
  '{type:"ask", from:"lin", slug:$s, question:"schema unclear", ts:$t}')
dm_to_inbox lin raj "$ask_raj" && ok "lin DM raj ONCE"

# (No reply within timeout.) Step 2: lin escalates to maya once.
escalate=$(jq -nc --arg s "$ASK_ID" --arg t "$(ts_now)" \
  '{type:"escalation", from:"lin", slug:$s, reason:"raj timeout, my human busy", ts:$t}')
dm_to_inbox lin maya "$escalate" && ok "lin escalated to maya ONCE"

# (No reply.) Step 3: lin emits no_human alert once.
alert=$(jq -nc --arg s "$ASK_ID" --arg t "$(ts_now)" \
  '{type:"no_human", from:"lin", slug:$s, reason:"escalation unresolved", ts:$t}')
as_role lin pub state.alert.no_human "$alert" >/dev/null 2>&1 \
  && ok "lin emitted state.alert.no_human ONCE"

sleep 1

# Assert AUDIT shows exactly: 1 raj inbox, 1 maya inbox, 1 alert. No more.
raj_count=$(audit_events_for_slug 'agents.raj.inbox'  "$ASK_ID" | grep -c '^.')
maya_count=$(audit_events_for_slug 'agents.maya.inbox' "$ASK_ID" | grep -c '^.')
alert_count=$(audit_events_for_slug 'state.alert.no_human' "$ASK_ID" | grep -c '^.')

[ "$raj_count"  = "1" ] && ok "exactly 1 DM to raj"  || bad "got $raj_count to raj (expected 1)"
[ "$maya_count" = "1" ] && ok "exactly 1 DM to maya" || bad "got $maya_count to maya (expected 1)"
[ "$alert_count" = "1" ] && ok "exactly 1 no_human alert" || bad "got $alert_count alerts"

# Restore.
echo -n '{"status":"available","since":"'"$(ts_now)"'"}' \
  | as_role sysadmin kv put team-state agent.lin.human >/dev/null

summary
