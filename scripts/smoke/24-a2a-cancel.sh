#!/usr/bin/env bash
# Smoke 24 — A2A cancel signal (slice 3 card 142).
#
# Verifies: worker accept loop honors cancel; inflight cleared;
# .status=canceled published; cross-role cancel denied (sanity).
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 24 A2A cancel ──"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

# Start priya accept loop.
WLOG=$(mktemp)
trap 'kill $(jobs -p) 2>/dev/null; rm -f "$WLOG"' EXIT

PYTHONPATH="$REPO_ROOT/mcp-server/src" "$PY" -c "
import asyncio
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.worker import start_accept_loop
async def main():
    c = TeamAlphaClient('priya', '$NATS_URL', '$SMOKE_PASS')
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

echo -n '{}' | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1

# Maya sends task to priya.
TID="t-cancel-$(date +%s)"
REQ=$(jq -nc --arg id "$TID" '{task_id:$id, skill:"terraform", payload:{summary:"x"}, from:"maya"}')
nats_as maya request "a2a.priya.tasks.send" "$REQ" --timeout 3s >/dev/null 2>&1 \
  && ok "maya dispatched $TID" || bad "dispatch failed"

sleep 0.5

# Cross-role cancel attempt (lin → priya) — denied.
assert_pub_denied lin "a2a.priya.tasks.$TID.cancel" '{}'

# Maya cancels.
CANCEL=$(jq -nc --arg id "$TID" '{task_id:$id, by:"maya", reason:"smoke-test"}')
nats_as maya pub "a2a.priya.tasks.$TID.cancel" "$CANCEL" >/dev/null 2>&1 \
  && ok "maya cancel published" || bad "maya cancel failed"

sleep 2

# Verify .status=canceled in A2A_TASKS.
cname="sm24-$$-$(date +%s%N)"
nats_as sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.priya.tasks.$TID.status" --pull --deliver=5m --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
states=$(nats_as sysadmin --timeout 2s consumer next A2A_TASKS "$cname" --count 10 --raw --wait 1s 2>/dev/null \
         | jq -cR 'fromjson? // empty | .state' | sort -u | tr '\n' ',' | sed 's/,$//')
nats_as sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1
case "$states" in
  *canceled*) ok "status=canceled observed" ;;
  *)          bad "canceled missing; got: $states" ;;
esac

# Inflight cleared.
inflight=$(nats_as sysadmin kv get team-state "a2a.priya.inflight" --raw 2>/dev/null || echo "")
if echo "$inflight" | grep -q "$TID"; then
  bad "inflight still has $TID"
else
  ok "inflight cleared"
fi

summary
