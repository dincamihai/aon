#!/usr/bin/env bash
# Scenario 03 — permission boundary: Sam tries production python claim,
# substrate rejects, Sam falls back to learning track.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 03: permission boundary respected (sam → learning fallback) ──"

# 1. Maya posts production python task.
TID=$(maya_post_task python medium "extract CLI from monolith")
[ -n "$TID" ] && ok "maya posted production python $TID" || bad "post failed"

# 2. Sam (denied for production python) tries to claim — must fail.
claim=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" '{slug:$s, by:"sam", ts:$t}')
err=$(as_role sam pub "board.tasks.python.claimed" "$claim" 2>&1 >/dev/null || true)
if echo "$err" | grep -qi "permissions violation"; then
  ok "sam correctly denied production python claim"
else
  bad "sam was NOT denied — got: $err"
fi

# 3. Sam falls back to learning track. Maya/Raj posts learning task; Sam claims.
LTID="learn-$(date +%s%N)"
learn_post=$(jq -nc --arg s "$LTID" --arg t "$(ts_now)" \
             '{task_id:$s, slug:$s, summary:"learn argparse basics", priority:"low",
               ts:$t, by:"raj", scope_hours:2, mentor:"raj"}')
as_role raj pub "board.learning.python.pending" "$learn_post" >/dev/null 2>&1 \
  && ok "raj posted learning task $LTID" || bad "raj post failed"

# Sam claims learning (allowed).
sam_claim=$(jq -nc --arg s "$LTID" --arg t "$(ts_now)" '{slug:$s, by:"sam", ts:$t}')
as_role sam pub "board.learning.python.claimed" "$sam_claim" >/dev/null 2>&1 \
  && ok "sam claimed learning python (fallback path)" \
  || bad "sam denied on learning track — substrate misconfigured"

sleep 1

# 4. Assert AUDIT: production claim NOT present, learning claim IS present.
prod_claim=$(audit_events_for_slug 'board.tasks.python.claimed' "$TID" | grep -c '^.')
[ "$prod_claim" -eq 0 ] && ok "no production claim in AUDIT for $TID (correctly blocked)" \
  || bad "production claim leaked to AUDIT: $prod_claim entries"

learn_claim=$(audit_events_for_slug 'board.learning.python.claimed' "$LTID" \
              | jq -r '.by' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
[ "$learn_claim" = "sam" ] && ok "AUDIT shows sam claimed learning python" \
  || bad "expected sam, got '$learn_claim'"

summary
