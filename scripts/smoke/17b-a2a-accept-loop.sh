#!/usr/bin/env bash
# Smoke 17b — A2A worker accept loop end-to-end (slice 2 card 131).
#
# Spawns a worker (priya) running the A2A accept loop in a Python
# subprocess. Maya sends tasks/send via raw NATS request. Worker
# auto-accepts, replies on _INBOX, publishes .status=working,
# records to KV inflight. Smoke verifies all three.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 17b A2A accept-loop end-to-end ──"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

# 1. Start worker accept loop in background.
WORKER_LOG=$(mktemp)
trap 'kill "$WORKER_PID" 2>/dev/null; rm -f "$WORKER_LOG"' EXIT

PYTHONPATH="$REPO_ROOT/mcp-server/src" \
  AON_NATS_URL="$NATS_URL" \
  "$PY" -c "
import asyncio, sys
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.worker import start_accept_loop

async def main():
    c = TeamAlphaClient('priya', '$NATS_URL', '$SMOKE_PASS')
    await c.nc()
    task = await start_accept_loop(c)
    print('LOOP-READY', flush=True)
    try:
        await task
    except asyncio.CancelledError:
        pass

asyncio.run(main())
" > "$WORKER_LOG" 2>&1 &
WORKER_PID=$!

# Wait for LOOP-READY (up to 8s).
for _ in $(seq 1 40); do
  grep -q LOOP-READY "$WORKER_LOG" 2>/dev/null && break
  sleep 0.2
done
if grep -q LOOP-READY "$WORKER_LOG"; then
  ok "worker accept loop running"
else
  bad "worker accept loop did not start; log:"
  sed 's/^/    /' "$WORKER_LOG" >&2
  exit 1
fi

# 2. Clear inflight before test.
echo -n '{}' | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1

# 3. Maya sends tasks/send via NATS request.
TASK_ID="t-$(date +%s)"
REQ=$(jq -nc --arg id "$TASK_ID" '{task_id:$id, skill:"terraform", payload:{summary:"smoke"}, from:"maya"}')
REPLY=$(nats_as maya request "a2a.priya.tasks.send" "$REQ" --timeout 5s 2>&1 | tail -3 || true)

if echo "$REPLY" | grep -qE '"ok"\s*:\s*true'; then
  ok "maya got ack {ok:true} from priya accept loop"
else
  bad "no ack; got: $REPLY"
fi
if echo "$REPLY" | grep -qE "\"task_id\"\s*:\s*\"$TASK_ID\""; then
  ok "ack carries correct task_id"
else
  bad "ack missing task_id; got: $REPLY"
fi
if echo "$REPLY" | grep -qE '"accepted_by"\s*:\s*"priya"'; then
  ok "ack identifies priya as acceptor"
else
  bad "ack accepted_by missing; got: $REPLY"
fi

# 4. Verify .status=working published on a2a.priya.tasks.<id>.status (via AUDIT lag).
sleep 1
STATUS=$(nats_as sysadmin stream subjects A2A_TASKS 2>/dev/null \
         | grep "a2a.priya.tasks.$TASK_ID.status" || true)
if [ -n "$STATUS" ]; then
  ok "A2A_TASKS contains status subject for $TASK_ID"
else
  # Subjects view may not be available; fall back to consumer fetch.
  cname="dbg-$$-$(date +%s%N)"
  nats_as sysadmin consumer add A2A_TASKS "$cname" --filter "a2a.priya.tasks.$TASK_ID.status" \
    --pull --deliver=all --ack=none --replay=instant --ephemeral --defaults >/dev/null 2>&1
  fetched=$(nats_as sysadmin --timeout 1s consumer next A2A_TASKS "$cname" --count 5 --raw --wait 500ms 2>/dev/null || true)
  nats_as sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1
  if echo "$fetched" | grep -q '"state":"working"'; then
    ok "status=working observed for $TASK_ID"
  else
    bad "no status=working event for $TASK_ID; got: $(echo "$fetched" | head -2)"
  fi
fi

# 5. Verify KV inflight has the task.
INFLIGHT=$(nats_as sysadmin kv get team-state "a2a.priya.inflight" --raw 2>/dev/null || echo "")
if echo "$INFLIGHT" | grep -q "\"$TASK_ID\""; then
  ok "KV a2a.priya.inflight records $TASK_ID"
else
  bad "KV inflight missing $TASK_ID; got: $INFLIGHT"
fi
if echo "$INFLIGHT" | grep -q '"state":"working"'; then
  ok "KV inflight state=working"
else
  bad "KV inflight state mismatch; got: $INFLIGHT"
fi

# 6. Schema-fail: missing skill should reply error, no inflight write.
BAD_REQ='{"task_id":"t-bad","payload":{}}'
BAD_REPLY=$(nats_as maya request "a2a.priya.tasks.send" "$BAD_REQ" --timeout 3s 2>&1 | tail -3 || true)
if echo "$BAD_REPLY" | grep -qE '"ok"\s*:\s*false'; then
  ok "schema-fail dispatch returns error reply"
else
  bad "schema-fail not rejected; got: $BAD_REPLY"
fi

# 7. Skill-mismatch: priya doesn't advertise 'ui' → reject.
BAD2=$(jq -nc '{task_id:"t-skill", skill:"ui", payload:{}, from:"maya"}')
BAD2_REPLY=$(nats_as maya request "a2a.priya.tasks.send" "$BAD2" --timeout 3s 2>&1 | tail -3 || true)
if echo "$BAD2_REPLY" | grep -q "does not advertise"; then
  ok "skill-mismatch dispatch rejected"
else
  bad "skill-mismatch not rejected; got: $BAD2_REPLY"
fi

# Cleanup KV.
echo -n '{}' | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1

summary
