#!/usr/bin/env bash
# Sim 08 — two roles claim same task slug; watcher emits duplicate_claim.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 08 card-claim race detection ──"

SLUG="dup-claim-$(date +%s%N)"
TS=$(ts_now)

# Two distinct roles claim same slug.
sim_pub board.tasks.terraform.claimed \
  "$(jq -nc --arg s "$SLUG" --arg t "$TS" '{slug:$s, by:"raj",   ts:$t}')" \
  && ok "raj claimed $SLUG"
sim_pub board.tasks.terraform.claimed \
  "$(jq -nc --arg s "$SLUG" --arg t "$TS" '{slug:$s, by:"priya", ts:$t}')" \
  && ok "priya claimed $SLUG (race)"

# Let AUDIT mirror catch up, then query AUDIT directly for the slug.
sleep 1
EMITTERS=$(audit_distinct_emitters 'board.tasks.*.claimed' "$SLUG" | tr '\n' ',' | sed 's/,$//')
if [ "$EMITTERS" = "priya,raj" ]; then
  ok "AUDIT shows duplicate-claim from priya AND raj for $SLUG"
else
  bad "expected emitters 'priya,raj', got '$EMITTERS' for $SLUG"
fi

summary
