#!/usr/bin/env bash
# Scenario 12 — dual-write replay parity (slice 3 card 143).
#
# Drives a substrate flow (pending → claimed → done) via direct
# NATS publish from each role, then triggers the bridge to mirror
# each substrate transition to A2A. Asserts AUDIT contains BOTH
# chains for the same logical task.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SIM_DIR/../.." && pwd)"
source "$SIM_DIR/_lib.sh"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

echo "── scenario 12: dual-write parity ──"

mirror() {
  local role="$1" sub_state="$2" slug="$3"
  PYTHONPATH="$REPO_ROOT/mcp-server/src" "$PY" -c "
import asyncio
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.bridge import mirror_substrate_to_a2a
async def main():
    c = TeamAlphaClient('$role', '$NATS_URL', '$SIM_CREDS_DIR/$role.creds')
    tid = await mirror_substrate_to_a2a(c, '$sub_state', '$slug')
    print(tid)
asyncio.run(main())
" 2>&1 | tail -1
}

# 1. Substrate flow: maya posts; priya claims; priya ships.
TID=$(maya_post_task terraform medium "dual-write parity test")
[ -n "$TID" ] && ok "maya posted task ($TID)" || bad "post failed"

worker_claim_and_ship priya terraform "$TID" sha-dw1 \
  && ok "priya claimed + shipped (substrate path)"

# 2. Trigger bridge for both transitions.
A2A_TID=$(mirror priya claimed "$TID")
[ "$A2A_TID" = "a2a:$TID" ] && ok "bridge claimed → working ($A2A_TID)" \
  || bad "bridge claimed unexpected: $A2A_TID"

mirror priya done "$TID" >/dev/null
ok "bridge done → completed published"

sleep 2

# 3. Substrate chain in AUDIT.
sub_events=$(audit_events_for_slug 'board.>' "$TID" 5m)
sub_count=$(echo "$sub_events" | grep -c '^.' || true)
[ "$sub_count" -ge 4 ] \
  && ok "substrate AUDIT has $sub_count events (pending+claimed+done+shipped)" \
  || bad "substrate AUDIT short: $sub_count"

# 4. A2A chain in AUDIT.
cname="sim12-$$-$(date +%s%N)"
as_role sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.priya.tasks.a2a:$TID.status" --pull --deliver=5m --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
states=$(as_role sysadmin --timeout 2s consumer next A2A_TASKS "$cname" --count 10 --raw --wait 1s 2>/dev/null \
         | jq -cR 'fromjson? // empty | .state' | sort -u | tr '\n' ',' | sed 's/,$//')
as_role sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1

case "$states" in
  *working*)   ok "A2A AUDIT has working" ;;
  *)           bad "A2A AUDIT missing working: $states" ;;
esac
case "$states" in
  *completed*) ok "A2A AUDIT has completed" ;;
  *)           bad "A2A AUDIT missing completed: $states" ;;
esac

# 5. Same logical task — task_id derived deterministically from slug.
[ "$A2A_TID" = "a2a:$TID" ] \
  && ok "A2A task_id maps deterministically to substrate slug"

summary
