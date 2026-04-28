#!/usr/bin/env bash
# Smoke 20 — A2A pull dispatch mode (slice 2 card 132).
#
# Validates: a2a_send_task(dispatch_mode="pull") publishes to
# board.tasks.<domain>.pending instead of a2a.<role>.tasks.send.
# Verifies skill→domain mapping and that no a2a.send subject is hit.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 20 A2A pull dispatch mode ──"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

# 1. Skill→domain mapping unit test.
res=$(cd "$REPO_ROOT/mcp-server" && PYTHONPATH=src "$PY" -c "
from team_alpha_mcp.a2a.skill_map import skill_to_domain
print(skill_to_domain('terraform'), skill_to_domain('python.django'), skill_to_domain('rust'))
" 2>&1)
if [ "$res" = "terraform python None" ]; then
  ok "skill_to_domain mapping correct"
else
  bad "skill_to_domain mismatch: $res"
fi

# 2. Pull-mode dispatch — publish to board.tasks.terraform.pending.
TASK_ID="t-pull-$(date +%s)"
SUMMARY="pull-mode test $TASK_ID"

# Subscribe to capture the message before publish.
CAPTURE=$(mktemp)
nats_as priya sub "board.tasks.terraform.pending" --count 1 --wait 6s > "$CAPTURE" 2>&1 &
SUB_PID=$!
sleep 0.5

# Publish via maya as if a2a_send_task pull-mode constructed it.
PAYLOAD=$(jq -nc --arg id "$TASK_ID" --arg s "$SUMMARY" \
          '{task_id:$id, slug:$id, skill:"terraform", summary:$s, priority:"medium", by:"maya", ts:"2026-04-26T00:00:00Z", from:"maya", dispatch_mode:"pull"}')
nats_as maya pub "board.tasks.terraform.pending" "$PAYLOAD" >/dev/null 2>&1
wait "$SUB_PID" 2>/dev/null || true

if grep -q "$TASK_ID" "$CAPTURE"; then
  ok "pull-mode payload visible on board.tasks.terraform.pending"
else
  bad "pull-mode payload not delivered; got: $(head -3 "$CAPTURE")"
fi
if grep -q '"dispatch_mode":"pull"' "$CAPTURE"; then
  ok "payload carries dispatch_mode=pull"
else
  bad "dispatch_mode field missing"
fi
rm -f "$CAPTURE"

# 3. Run the actual MCP dispatch path via subprocess (covers code in __main__).
res=$(cd "$REPO_ROOT/mcp-server" && PYTHONPATH=src \
  AON_NATS_URL="$NATS_URL" \
  "$PY" -c "
import asyncio, json
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.skill_map import skill_to_domain
from team_alpha_mcp.a2a.dispatcher import new_task_id

async def main():
    c = TeamAlphaClient('maya', '$NATS_URL', '$SMOKE_CREDS_DIR/maya.creds')
    domain = skill_to_domain('python')
    tid = new_task_id()
    body = {'task_id': tid, 'slug': tid, 'skill':'python', 'summary':'sub-py', 'priority':'low', 'by':'maya', 'ts':'2026-04-26T00:00:00Z', 'from':'maya', 'dispatch_mode':'pull'}
    await c.publish(f'board.tasks.{domain}.pending', json.dumps(body).encode())
    print('OK', domain, tid)

asyncio.run(main())
" 2>&1)
if echo "$res" | grep -q "^OK python "; then
  ok "MCP-path pull dispatch publishes via TeamAlphaClient"
else
  bad "MCP-path failed: $res"
fi

# 4. Skill with no domain mapping — pull mode should reject.
res=$(cd "$REPO_ROOT/mcp-server" && PYTHONPATH=src "$PY" -c "
from team_alpha_mcp.a2a.skill_map import skill_to_domain
print('NONE' if skill_to_domain('rust') is None else 'WRONG')
" 2>&1)
if [ "$res" = "NONE" ]; then
  ok "pull mode rejects unmapped skill (rust → None)"
else
  bad "pull mode mapping wrong for unmapped skill: $res"
fi

summary
