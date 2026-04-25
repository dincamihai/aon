#!/usr/bin/env bash
# Sim 10 — stale claim never followed by .done; watcher emits stale_claim.
# Uses STALE_CLAIM_SEC=1 to compress timing for test.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 10 stale-claim GC ──"

SLUG="stale-$(date +%s%N)"
# Backdate ts by 5s to simulate old claim.
TS=$(date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
   || date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ)

sim_pub board.tasks.go.claimed \
  "$(jq -nc --arg s "$SLUG" --arg t "$TS" '{slug:$s, by:"diego", ts:$t}')" \
  && ok "diego claimed $SLUG (backdated 5s)"

sleep 1
# Targeted check: claim event lands in AUDIT with backdated ts. Watcher's
# tick-mode stale-detection is exercised in card 65 sim (heavy, requires
# small AUDIT). Here verify substrate-level: backdated claim is queryable.
EMITTERS=$(audit_distinct_emitters 'board.tasks.*.claimed' "$SLUG" | tr '\n' ',' | sed 's/,$//')
if [ "$EMITTERS" = "diego" ]; then
  ok "AUDIT records backdated claim by diego for $SLUG (stale-detection input present)"
else
  bad "expected 'diego', got '$EMITTERS' for $SLUG"
fi

summary
