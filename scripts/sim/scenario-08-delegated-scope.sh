#!/usr/bin/env bash
# Scenario 08 — scoped delegation + HITL gate.
#
# Lin's human delegates her for `python` only. Maya posts a python task
# (in scope) and a ui task (out of scope). Lin's protocol behavior:
#   - python task: claim AUTONOMOUSLY (no peer DM, no hitl_check)
#   - ui task: emit `hitl_check` event to maya's inbox BEFORE claiming
#
# Substrate cannot enforce this scope (ACL only covers domain-as-domain,
# not delegation policy). Test verifies the protocol-level signaling: the
# right events fire in the right order so Maya can audit/intervene.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 08: scoped delegation + HITL gate (lin scope=python) ──"

UNTIL=$(date -u -v+8H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d '+8 hours' +%Y-%m-%dT%H:%M:%SZ)

# 1. Lin's human delegates her for python only.
DELEGATED=$(jq -nc --arg t "$(ts_now)" --arg u "$UNTIL" \
  '{status:"delegated", scope:["python"], until:$u, since:$t}')
echo -n "$DELEGATED" | as_role lin kv put team-state agent.lin.human >/dev/null \
  && ok "lin.human=delegated scope=[python]"
as_role lin pub state.agent.lin.human "$DELEGATED" >/dev/null 2>&1 \
  && ok "lin emitted state event"

# 2. Maya posts python (in scope).
PY="py-$(date +%s%N)"
maya_py=$(jq -nc --arg s "$PY" --arg t "$(ts_now)" \
  '{task_id:$s, slug:$s, summary:"refactor argparse", priority:"medium", ts:$t, by:"maya"}')
as_role maya pub board.tasks.python.pending "$maya_py" >/dev/null 2>&1 \
  && ok "maya posted python ($PY)"

# Lin claims autonomously — no hitl_check event published.
lin_py=$(jq -nc --arg s "$PY" --arg t "$(ts_now)" \
  '{slug:$s, by:"lin", ts:$t, autonomous:true}')
as_role lin pub board.tasks.python.claimed "$lin_py" >/dev/null 2>&1 \
  && ok "lin claimed python autonomously (in scope)"

# 3. Maya posts ui (out of scope for delegation).
UI="ui-$(date +%s%N)"
maya_ui=$(jq -nc --arg s "$UI" --arg t "$(ts_now)" \
  '{task_id:$s, slug:$s, summary:"settings menu polish", priority:"medium", ts:$t, by:"maya"}')
as_role maya pub board.tasks.ui.pending "$maya_ui" >/dev/null 2>&1 \
  && ok "maya posted ui ($UI)"

# Lin emits hitl_check (ASK maya before claiming out-of-scope).
hitl=$(jq -nc --arg s "$UI" --arg t "$(ts_now)" \
  '{type:"hitl_check", from:"lin", slug:$s, reason:"delegation scope=[python] does not cover ui", ts:$t}')
dm_to_inbox lin maya "$hitl" && ok "lin DM maya hitl_check (out of scope)"

# Lin does NOT claim until maya replies. Sim doesn't mock the reply.

sleep 1

# Assertions: lin claimed python in audit, did NOT claim ui.
py_claim=$(audit_events_for_slug 'board.tasks.python.claimed' "$PY" \
           | jq -r '.by' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
[ "$py_claim" = "lin" ] && ok "AUDIT: python claimed by lin" \
  || bad "expected python claim by lin, got '$py_claim'"

ui_claim=$(audit_events_for_slug 'board.tasks.ui.claimed' "$UI" | grep -c '^.')
[ "$ui_claim" = "0" ] && ok "AUDIT: ui NOT claimed (waiting for maya)" \
  || bad "ui claimed when it should be gated: count=$ui_claim"

# hitl_check event visible to maya.
hitl_seen=$(audit_events_for_slug 'agents.maya.inbox' "$UI" \
            | jq -r '.type' 2>/dev/null | grep -c hitl_check)
[ "$hitl_seen" -ge 1 ] && ok "AUDIT: hitl_check DM to maya recorded" \
  || bad "no hitl_check event seen in maya inbox"

# Restore.
echo -n '{"status":"available","since":"'"$(ts_now)"'"}' \
  | as_role lin kv put team-state agent.lin.human >/dev/null 2>&1

summary
