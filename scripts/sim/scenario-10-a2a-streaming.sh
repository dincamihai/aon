#!/usr/bin/env bash
# Scenario 10 — A2A streaming chunks (slice 3 card 141).
#
# Worker emits 5 .message chunks during work; Maya observes via
# subscription on a2a.<role>.tasks.<id>.message in order.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SIM_DIR/../.." && pwd)"
source "$SIM_DIR/_lib.sh"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

echo "── scenario 10: A2A streaming ──"

# Start lin's accept loop AND a custom message emitter.
WLOG=$(mktemp); CAPLOG=$(mktemp)
trap 'kill $(jobs -p) 2>/dev/null; rm -f "$WLOG" "$CAPLOG"' EXIT

PYTHONPATH="$REPO_ROOT/mcp-server/src" "$PY" -c "
import asyncio, json
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.worker import start_accept_loop, _publish_status, _record_inflight
from team_alpha_mcp.a2a.cards import card_skill_tier
from team_alpha_mcp.a2a.schemas import validate_task_send

async def custom_handle(c, msg):
    body = json.loads(msg.data.decode())
    validate_task_send(body)
    if card_skill_tier(c.role, body['skill']) is None:
        if msg.reply: await c.publish(msg.reply, json.dumps({'ok':False,'error':'skill'}).encode())
        return
    tid = body['task_id']
    await _record_inflight(c, tid, body)
    await _publish_status(c, tid, 'working')
    if msg.reply:
        await c.publish(msg.reply, json.dumps({'ok':True,'task_id':tid,'accepted_by':c.role}).encode())
    # Stream 5 chunks then completed.
    for i in range(5):
        await asyncio.sleep(0.1)
        body_msg = {'task_id':tid,'kind':'text','chunk':f'chunk-{i}','by':c.role,'ts':'2026-04-26T00:00:00Z'}
        await c.publish(f'a2a.{c.role}.tasks.{tid}.message', json.dumps(body_msg).encode())
    await _publish_status(c, tid, 'completed')

async def main():
    c = TeamAlphaClient('lin', '$NATS_URL', '$SIM_PASS')
    nc = await c.nc()
    async def cb(m):
        try: await custom_handle(c, m)
        except Exception as e: print('ERR', e, flush=True)
    await nc.subscribe(f'a2a.lin.tasks.send', cb=cb)
    print('LOOP-READY', flush=True)
    while True: await asyncio.sleep(3600)
asyncio.run(main())
" > "$WLOG" 2>&1 &
WPID=$!
for _ in $(seq 1 40); do grep -q LOOP-READY "$WLOG" && break; sleep 0.2; done
grep -q LOOP-READY "$WLOG" && ok "lin streaming worker ready" || { bad "loop never ready: $(cat "$WLOG")"; exit 1; }

# Clear inflight.
echo -n '{}' | as_role sysadmin kv put team-state "a2a.lin.inflight" >/dev/null 2>&1

# Maya dispatches.
TID=$(PYTHONPATH="$REPO_ROOT/mcp-server/src" "$PY" -c "
import asyncio, json
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.dispatcher import dispatch_task
async def main():
    c = TeamAlphaClient('maya', '$NATS_URL', '$SIM_PASS')
    res = await dispatch_task(c, skill='ui', payload={'summary':'stream'})
    print(res['task_id'])
asyncio.run(main())
" 2>&1 | tail -1)
[ -n "$TID" ] && ok "maya dispatched ($TID)" || bad "no task_id"

# Wait for stream completion + AUDIT lag.
sleep 6

# Fetch .message events for $TID via consumer.
cname="sim10-$$-$(date +%s%N)"
as_role sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.lin.tasks.$TID.message" --pull --deliver=5m --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
chunks=$(as_role sysadmin --timeout 2s consumer next A2A_TASKS "$cname" --count 20 --raw --wait 1s 2>/dev/null \
         | jq -cR 'fromjson? // empty | select(.task_id=="'"$TID"'") | .chunk')
as_role sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1

n=$(echo "$chunks" | grep -c chunk- || true)
[ "$n" -ge 5 ] && ok "received $n .message chunks (expected ≥5)" || bad "chunks=$n; got: $chunks"

# Order check — chunk-0..chunk-4 in sequence.
ordered=$(echo "$chunks" | tr -d '"' | tr '\n' ' ')
case "$ordered" in
  *"chunk-0 chunk-1 chunk-2 chunk-3 chunk-4"*) ok "chunks in order" ;;
  *) bad "chunk order wrong: $ordered" ;;
esac

# AUDIT contains working + completed for $TID.
cname2="sim10s-$$-$(date +%s%N)"
as_role sysadmin consumer add A2A_TASKS "$cname2" \
  --filter "a2a.lin.tasks.$TID.status" --pull --deliver=5m --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
states=$(as_role sysadmin --timeout 2s consumer next A2A_TASKS "$cname2" --count 10 --raw --wait 1s 2>/dev/null \
         | jq -cR 'fromjson? // empty | .state' | sort -u | tr '\n' ',' | sed 's/,$//')
as_role sysadmin consumer rm A2A_TASKS "$cname2" -f >/dev/null 2>&1
case "$states" in
  *working*) ok "AUDIT contains working" ;;
  *)         bad "no working state; got: $states" ;;
esac
case "$states" in
  *completed*) ok "AUDIT contains completed" ;;
  *)           bad "no completed; got: $states" ;;
esac

echo -n '{}' | as_role sysadmin kv put team-state "a2a.lin.inflight" >/dev/null 2>&1
summary
