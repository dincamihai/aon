#!/usr/bin/env bash
# Scenario 11 — A2A cancel signal (slice 3 card 142).
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SIM_DIR/../.." && pwd)"
source "$SIM_DIR/_lib.sh"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

echo "── scenario 11: A2A cancel ──"

# Start priya accept loop (slice 2 worker — handles cancel via slice 3).
WLOG=$(mktemp)
trap 'kill $(jobs -p) 2>/dev/null; rm -f "$WLOG"' EXIT

PYTHONPATH="$REPO_ROOT/mcp-server/src" "$PY" -c "
import asyncio
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.worker import start_accept_loop
async def main():
    c = TeamAlphaClient('priya', '$NATS_URL', '$SIM_PASS')
    await c.nc()
    t = await start_accept_loop(c)
    print('LOOP-READY', flush=True)
    try: await t
    except asyncio.CancelledError: pass
asyncio.run(main())
" > "$WLOG" 2>&1 &
WPID=$!
for _ in $(seq 1 40); do grep -q LOOP-READY "$WLOG" && break; sleep 0.2; done
grep -q LOOP-READY "$WLOG" && ok "priya accept loop ready" || { bad "loop not ready"; exit 1; }

echo -n '{}' | as_role sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1

# Maya dispatches.
TID=$(PYTHONPATH="$REPO_ROOT/mcp-server/src" "$PY" -c "
import asyncio, json
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.dispatcher import dispatch_task
async def main():
    c = TeamAlphaClient('maya', '$NATS_URL', '$SIM_PASS')
    res = await dispatch_task(c, skill='terraform', payload={'summary':'cancel-test'})
    print(res['task_id'])
asyncio.run(main())
" 2>&1 | tail -1)
[ -n "$TID" ] && ok "maya dispatched ($TID)" || bad "no task_id"

# Wait for working state to settle.
sleep 0.5

# Maya publishes cancel.
CANCEL=$(jq -nc --arg id "$TID" --arg t "$(ts_now)" \
         '{task_id:$id, by:"maya", ts:$t, reason:"rescoped"}')
as_role maya pub "a2a.priya.tasks.$TID.cancel" "$CANCEL" >/dev/null 2>&1 \
  && ok "maya published cancel" || bad "maya cancel publish failed"

# Worker should emit .status=canceled within 2s.
sleep 3

# Check status events for $TID.
cname="sim11-$$-$(date +%s%N)"
as_role sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.priya.tasks.$TID.status" --pull --deliver=5m --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
states=$(as_role sysadmin --timeout 2s consumer next A2A_TASKS "$cname" --count 10 --raw --wait 1s 2>/dev/null \
         | jq -cR 'fromjson? // empty | .state' | sort -u | tr '\n' ',' | sed 's/,$//')
as_role sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1

case "$states" in
  *canceled*) ok "AUDIT contains canceled state" ;;
  *)          bad "no canceled state; got: $states" ;;
esac
case "$states" in
  *working*) ok "AUDIT also has working state" ;;
  *)         bad "no working state; got: $states" ;;
esac

# Inflight cleared.
inflight=$(as_role sysadmin kv get team-state "a2a.priya.inflight" --raw 2>/dev/null || echo "")
if echo "$inflight" | grep -q "$TID"; then
  bad "inflight still has $TID after cancel"
else
  ok "inflight cleared after cancel"
fi

summary
