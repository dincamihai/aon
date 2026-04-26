#!/usr/bin/env bash
# Smoke 23 — A2A .message streaming subject (slice 3 card 141).
#
# Validates: a2a_emit_message tool publishes on the right subject;
# A2A_TASKS stores chunks; cross-role pub denied (sanity).
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 23 A2A streaming subject ──"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

TID="t-stream-$(date +%s)"

# Publish 3 chunks via raj as if a2a_emit_message did it.
for i in 0 1 2; do
  body=$(jq -nc --arg id "$TID" --arg c "chunk-$i" \
         '{task_id:$id, kind:"text", chunk:$c, by:"raj", ts:"2026-04-26T00:00:00Z"}')
  nats_as raj pub "a2a.raj.tasks.$TID.message" "$body" >/dev/null 2>&1
done

sleep 1

# Fetch and count.
cname="sm23-$$-$(date +%s%N)"
nats_as sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.raj.tasks.$TID.message" --pull --deliver=5m --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
chunks=$(nats_as sysadmin --timeout 2s consumer next A2A_TASKS "$cname" --count 10 --raw --wait 1s 2>/dev/null \
         | jq -cR 'fromjson? // empty | .chunk')
nats_as sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1

n=$(echo "$chunks" | grep -c "chunk-" || true)
[ "$n" -ge 3 ] && ok "A2A_TASKS contains $n streaming chunks for $TID" \
  || bad "expected ≥3 chunks, got $n: $chunks"

# Cross-role pub denied: lin cannot publish on a2a.raj.tasks.<x>.message.
assert_pub_denied lin "a2a.raj.tasks.$TID.message" '{"task_id":"x","chunk":"y"}'

# MCP-path: invoke a2a_emit_message via subprocess.
res=$(cd "$REPO_ROOT/mcp-server" && PYTHONPATH=src \
  TEAM_ALPHA_NATS_URL="$NATS_URL" "$PY" -c "
import asyncio, json
from team_alpha_mcp.client import TeamAlphaClient
async def main():
    c = TeamAlphaClient('priya', '$NATS_URL', '$SMOKE_PASS')
    body = {'task_id':'$TID-mcp','kind':'text','chunk':'mcp-payload','by':'priya','ts':'2026-04-26T00:00:00Z'}
    await c.publish(f'a2a.priya.tasks.$TID-mcp.message', json.dumps(body).encode())
    print('OK')
asyncio.run(main())
" 2>&1 | tail -1)
[ "$res" = "OK" ] && ok "MCP path publishes via TeamAlphaClient" || bad "MCP path: $res"

summary
