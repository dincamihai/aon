#!/usr/bin/env bash
# Smoke 25 — A2A dual-write cutover (slice 3 card 143).
#
# Verifies the bridge: each substrate state transition mirrors to
# the matching A2A canonical state on a2a.<role>.tasks.<id>.status.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

echo "── 25 A2A dual-write bridge ──"

run_mirror() {
  local role="$1" sub_state="$2" slug="$3"
  PYTHONPATH="$REPO_ROOT/mcp-server/src" "$PY" -c "
import asyncio
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.bridge import mirror_substrate_to_a2a
async def main():
    c = TeamAlphaClient('$role', '$NATS_URL', '$SMOKE_PASS')
    tid = await mirror_substrate_to_a2a(c, '$sub_state', '$slug')
    print(tid)
asyncio.run(main())
" 2>&1 | tail -1
}

# 1. Test mapping: substrate claimed → A2A working.
SLUG="dw-$(date +%s)"
echo -n '{}' | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1
TID=$(run_mirror priya claimed "$SLUG")
[ "$TID" = "a2a:$SLUG" ] && ok "derive_task_id stable (a2a:$SLUG)" || bad "task_id wrong: $TID"

sleep 1
state=$(nats_as sysadmin stream subjects A2A_TASKS 2>/dev/null \
        | grep -c "a2a.priya.tasks.a2a:$SLUG.status" || true)
[ "$state" -ge 1 ] && ok "A2A status subject created for claimed mirror" \
  || bad "no a2a.priya.tasks.a2a:$SLUG.status (state=$state)"

# Read most recent .status payload — should be state=working.
cname="dw1-$$-$(date +%s%N)"
nats_as sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.priya.tasks.a2a:$SLUG.status" --pull --deliver=last --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
last=$(nats_as sysadmin --timeout 1s consumer next A2A_TASKS "$cname" --count 1 --raw --wait 500ms 2>/dev/null)
nats_as sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1
echo "$last" | grep -q '"state":"working"' && ok "claimed → working state" \
  || bad "expected state=working; got: $last"
echo "$last" | grep -q '"from_substrate":"claimed"' && ok "from_substrate field carried" \
  || bad "from_substrate missing"

# 2. blocked → input-required reason="blocked".
TID=$(run_mirror priya blocked "$SLUG")
sleep 0.5
cname="dw2-$$-$(date +%s%N)"
nats_as sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.priya.tasks.a2a:$SLUG.status" --pull --deliver=last --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
last=$(nats_as sysadmin --timeout 1s consumer next A2A_TASKS "$cname" --count 1 --raw --wait 500ms 2>/dev/null)
nats_as sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1
echo "$last" | grep -q '"state":"input-required"' && ok "blocked → input-required" \
  || bad "blocked mapping wrong: $last"

# 3. parked → input-required reason="preempted".
SLUG2="dw-park-$(date +%s)"
run_mirror priya parked "$SLUG2" >/dev/null
sleep 0.5
cname="dw3-$$-$(date +%s%N)"
nats_as sysadmin consumer add A2A_TASKS "$cname" \
  --filter "a2a.priya.tasks.a2a:$SLUG2.status" --pull --deliver=last --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
last=$(nats_as sysadmin --timeout 1s consumer next A2A_TASKS "$cname" --count 1 --raw --wait 500ms 2>/dev/null)
nats_as sysadmin consumer rm A2A_TASKS "$cname" -f >/dev/null 2>&1
echo "$last" | grep -q '"state":"input-required"' \
  && echo "$last" | grep -q '"reason":"preempted"' \
  && ok "parked → input-required reason=preempted" \
  || bad "parked mapping wrong: $last"

# 4. done → completed (terminal — clears inflight).
SLUG3="dw-done-$(date +%s)"
echo -n '{}' | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1
run_mirror priya claimed "$SLUG3" >/dev/null
run_mirror priya done    "$SLUG3" >/dev/null
sleep 0.5
inflight=$(nats_as sysadmin kv get team-state "a2a.priya.inflight" --raw 2>/dev/null || echo "")
if echo "$inflight" | grep -q "a2a:$SLUG3"; then
  bad "inflight still has $SLUG3 after done"
else
  ok "inflight cleared after done (terminal)"
fi

# Cleanup.
echo -n '{}' | nats_as sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1
summary
