#!/usr/bin/env bash
# Smoke 17 — A2A slice 1 roundtrip + ACL.
#
# Validates:
#   - agent cards generator is idempotent (gen-agent-cards.py)
#   - cards resolve correctly (terraform → priya, raj)
#   - ACL: maya can pub a2a.<role>.tasks.send
#   - ACL: worker can pub a2a.<self>.tasks.<id>.status
#   - ACL: worker cannot pub a2a.<other>.tasks.>
#   - ACL: non-maya worker cannot pub a2a.*.tasks.send
#   - lifecycle.py transitions reject illegal moves
#
# Requires bootstrap.sh already run (A2A_TASKS, A2A_DISC streams exist).
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 17 A2A slice 1 roundtrip ──"

# ── 1. generator idempotency ────────────────────────────────────────────
out=$(python3 "$REPO_ROOT/scripts/gen-agent-cards.py" 2>&1)
out2=$(python3 "$REPO_ROOT/scripts/gen-agent-cards.py" 2>&1)
if echo "$out2" | grep -q "no changes"; then
  ok "gen-agent-cards.py idempotent"
else
  bad "gen-agent-cards.py not idempotent: $out2"
fi

# ── 2. card resolver ────────────────────────────────────────────────────
res=$(cd "$REPO_ROOT/mcp-server" && python3 -c "
import sys; sys.path.insert(0,'src')
from team_alpha_mcp.a2a import cards
print(','.join(cards.resolve_by_skill('terraform','primary')))
" 2>&1)
if [ "$res" = "priya,raj" ]; then
  ok "resolve_by_skill('terraform','primary') = priya,raj"
else
  bad "resolve mismatch: got '$res'"
fi

# ── 3. lifecycle ────────────────────────────────────────────────────────
res=$(cd "$REPO_ROOT/mcp-server" && python3 -c "
import sys; sys.path.insert(0,'src')
from team_alpha_mcp.a2a import lifecycle as L
L.transition('submitted','working')
L.transition('working','completed')
try:
  L.transition('completed','working'); print('FAIL-no-raise')
except L.LifecycleError: print('terminal-ok')
" 2>&1)
if [ "$res" = "terminal-ok" ]; then
  ok "lifecycle terminal transition rejected"
else
  bad "lifecycle test: $res"
fi

# ── 4. ACL: maya dispatches to a worker ─────────────────────────────────
assert_pub_ok    maya  "a2a.priya.tasks.send"     '{"task_id":"t-test","skill":"terraform","payload":{}}'
assert_pub_denied raj  "a2a.priya.tasks.send"     '{}'
assert_pub_denied sam  "a2a.lin.tasks.send"       '{}'

# ── 5. ACL: worker publishes status on own subtree ──────────────────────
assert_pub_ok     priya "a2a.priya.tasks.t-test.status"  '{"task_id":"t-test","state":"working","by":"priya"}'
assert_pub_ok     priya "a2a.priya.tasks.t-test.message" '{"chunk":"hello"}'

# ── 6. ACL: worker cannot publish to other worker's subtree ─────────────
assert_pub_denied priya "a2a.lin.tasks.t-other.status"   '{}'
assert_pub_denied lin   "a2a.priya.tasks.t-test.status"  '{}'

# ── 7. ACL: workers can subscribe to own send subject ───────────────────
assert_sub_ok     priya "a2a.priya.tasks.send"
assert_sub_ok     lin   "a2a.lin.tasks.send"

# ── 8. AUDIT mirrors a2a status (best-effort) ───────────────────────────
# Already published t-test.status above; check AUDIT has it.
cnt=$(nats_as sysadmin stream view AUDIT --subject "a2a.priya.tasks.t-test.status" 2>/dev/null | grep -c "working" || true)
if [ "$cnt" -ge 1 ]; then
  ok "AUDIT mirrors a2a.priya.tasks.t-test.status"
else
  skip "AUDIT mirror not yet visible (source lag) — non-fatal"
fi

# ── 9. discovery subject ACL ────────────────────────────────────────────
assert_pub_ok     priya "a2a.discovery.priya"     '{"name":"priya","version":"1.0"}'
assert_pub_denied lin   "a2a.discovery.priya"     '{}'

summary
