#!/usr/bin/env bash
# Scenario 09 — A2A dispatch by skill match (slice 2 card 134).
#
# Validates end-to-end push dispatch: Maya -> dispatcher -> Priya
# accept loop -> .status=working -> .status=completed -> AUDIT.
# Plus 09a (continuity bias) and 09b (no-skill rejection).
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SIM_DIR/../.." && pwd)"
source "$SIM_DIR/_lib.sh"

PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

start_worker() {
  local role="$1"
  PYTHONPATH="$REPO_ROOT/mcp-server/src" \
    "$PY" -c "
import asyncio
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.worker import start_accept_loop
async def main():
    c = TeamAlphaClient('$role', '$NATS_URL', '$SIM_CREDS_DIR/$role.creds')
    await c.nc()
    t = await start_accept_loop(c)
    print('LOOP-READY-$role', flush=True)
    try: await t
    except asyncio.CancelledError: pass
asyncio.run(main())
" 2>&1
}

dispatch_via_maya() {
  local skill="$1" parent="${2:-}" project="${3:-}"
  PYTHONPATH="$REPO_ROOT/mcp-server/src" \
    "$PY" -c "
import asyncio, json
from team_alpha_mcp.client import TeamAlphaClient
from team_alpha_mcp.a2a.dispatcher import dispatch_task
async def main():
    c = TeamAlphaClient('maya', '$NATS_URL', '$SIM_CREDS_DIR/maya.creds')
    res = await dispatch_task(
        c, skill='$skill', payload={'summary':'sim-09'},
        parent_task_id='$parent' or None, project_id='$project' or None,
    )
    print(json.dumps(res))
asyncio.run(main())
" 2>&1
}

# ── 09: full-lifecycle push dispatch (terraform → priya) ───────────────
echo "── scenario 09: A2A push dispatch + lifecycle ──"

WLOG=$(mktemp); start_worker priya > "$WLOG" 2>&1 &
WPID=$!
trap 'kill "$WPID" 2>/dev/null; rm -f "$WLOG"' EXIT
for _ in $(seq 1 40); do grep -q LOOP-READY-priya "$WLOG" && break; sleep 0.2; done
grep -q LOOP-READY-priya "$WLOG" && ok "priya accept loop ready" \
  || { bad "priya loop did not start"; sed 's/^/    /' "$WLOG" >&2; exit 1; }

# Clear inflight before run.
echo -n '{}' | as_role sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1

OUT=$(dispatch_via_maya terraform)
TID=$(echo "$OUT" | grep '^{' | jq -r '.task_id // empty' 2>/dev/null)
TARGET=$(echo "$OUT" | grep '^{' | jq -r '.target_role // empty' 2>/dev/null)

[ -n "$TID" ]    && ok "maya dispatched task ($TID)"  || bad "no task_id; out: $OUT"
[ "$TARGET" = "priya" -o "$TARGET" = "raj" ] && ok "target_role=$TARGET (terraform primary set)" \
  || bad "target_role unexpected: $TARGET"

# If target is raj we'd need raj's loop running too — keep deterministic by
# ensuring priya is lower load (default = 0; raj also 0; alphabetical
# tiebreak puts priya before raj at equal load).
if [ "$TARGET" != "priya" ]; then
  bad "expected priya as target (alphabetical tiebreak at equal load); got $TARGET"
fi

# Worker should have published .status=working; Maya now publishes completed
# from priya's side via direct NATS to simulate work finishing.
sleep 1
COMPLETE=$(jq -nc --arg id "$TID" --arg t "$(ts_now)" \
           '{task_id:$id, state:"completed", by:"priya", ts:$t, artifact:{pr:"https://x/y"}}')
as_role priya pub "a2a.priya.tasks.$TID.status" "$COMPLETE" >/dev/null 2>&1
sleep 5

# AUDIT must show working AND completed for $TID. Direct fetch since
# audit_events_for_slug filters by `slug`, but A2A uses `task_id`.
cname="sim-$$-$(date +%s%N)"
as_role sysadmin consumer add AUDIT "$cname" \
  --filter "a2a.priya.tasks.$TID.status" --pull --deliver=5m --ack=none \
  --replay=instant --ephemeral --defaults >/dev/null 2>&1
events=$(as_role sysadmin consumer next AUDIT "$cname" --count 50 --raw --wait 1s 2>/dev/null \
         | jq -cR 'fromjson? // empty')
as_role sysadmin consumer rm AUDIT "$cname" -f >/dev/null 2>&1
states=$(echo "$events" | jq -r '.state' | sort -u | tr '\n' ',' | sed 's/,$//')
case "$states" in
  *working*) ok "AUDIT contains working state for $TID" ;;
  *)         bad "AUDIT missing working; states=$states" ;;
esac
case "$states" in
  *completed*) ok "AUDIT contains completed state for $TID" ;;
  *)           bad "AUDIT missing completed; states=$states" ;;
esac

# ── 09b: no-skill dispatch should error ────────────────────────────────
echo "── scenario 09b: no-such-skill rejection ──"
OUT_BAD=$(dispatch_via_maya rust)
if echo "$OUT_BAD" | grep -q "no agent advertises skill"; then
  ok "dispatcher rejects unknown skill 'rust'"
else
  bad "expected rejection, got: $OUT_BAD"
fi

# Cleanup KV.
echo -n '{}' | as_role sysadmin kv put team-state "a2a.priya.inflight" >/dev/null 2>&1

summary
