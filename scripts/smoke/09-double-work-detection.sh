#!/usr/bin/env bash
# Sim 09 — two roles ship same slug; watcher emits duplicate_result.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 09 double-work (duplicate result) ──"

SLUG="dup-ship-$(date +%s%N)"
TS=$(ts_now)

sim_pub board.results.terraform.shipped \
  "$(jq -nc --arg s "$SLUG" --arg t "$TS" '{slug:$s, by:"raj",   ts:$t, sha:"abc1234"}')" \
  && ok "raj shipped $SLUG"
sim_pub board.results.terraform.shipped \
  "$(jq -nc --arg s "$SLUG" --arg t "$TS" '{slug:$s, by:"priya", ts:$t, sha:"def5678"}')" \
  && ok "priya shipped $SLUG (double-work)"

sleep 1
EMITTERS=$(audit_distinct_emitters 'board.results.>' "$SLUG" | tr '\n' ',' | sed 's/,$//')
if [ "$EMITTERS" = "priya,raj" ]; then
  ok "AUDIT shows duplicate-result from priya AND raj for $SLUG"
else
  bad "expected emitters 'priya,raj', got '$EMITTERS' for $SLUG"
fi

summary
