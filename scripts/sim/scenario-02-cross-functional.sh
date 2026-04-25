#!/usr/bin/env bash
# Scenario 02 — cross-functional: Maya posts fullstack; Raj claims; Raj DMs
# Sam (UI) and Diego (Go) for pairing; both reply on Raj's inbox; Raj ships.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 02: cross-functional pairing (maya → raj + sam + diego) ──"

TID=$(maya_post_task fullstack medium "build user settings page")
[ -n "$TID" ] && ok "maya posted fullstack $TID" || bad "post failed"

# Raj claims fullstack.
claim=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" '{slug:$s, by:"raj", ts:$t}')
as_role raj pub "board.tasks.fullstack.claimed" "$claim" >/dev/null 2>&1 \
  && ok "raj claimed fullstack" || bad "raj claim failed"

# Raj DMs sam + diego asking for pairing time.
ask_sam=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" \
          '{type:"pair_request", from:"raj", slug:$s, hours:2, topic:"settings UI", ts:$t}')
ask_diego=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" \
          '{type:"pair_request", from:"raj", slug:$s, hours:2, topic:"settings backend", ts:$t}')
dm_to_inbox raj sam   "$ask_sam"   && ok "raj DM sam"
dm_to_inbox raj diego "$ask_diego" && ok "raj DM diego"

# Sam + Diego reply.
reply_sam=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" \
            '{type:"pair_accept", from:"sam", slug:$s, when:"today 14:00", ts:$t}')
reply_diego=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" \
            '{type:"pair_accept", from:"diego", slug:$s, when:"today 15:30", ts:$t}')
dm_to_inbox sam   raj "$reply_sam"   && ok "sam replied to raj"
dm_to_inbox diego raj "$reply_diego" && ok "diego replied to raj"

# Raj ships (proxy for "after pairing, raj integrated everyone's input").
done=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" '{slug:$s, by:"raj", ts:$t}')
shipped=$(jq -nc --arg s "$TID" --arg t "$(ts_now)" --arg sha sha-raj-1 \
          '{slug:$s, by:"raj", ts:$t, sha:$sha, paired_with:["sam","diego"]}')
as_role raj pub "board.tasks.fullstack.done" "$done" >/dev/null 2>&1
as_role raj pub "board.results.fullstack.shipped" "$shipped" >/dev/null 2>&1
ok "raj shipped"

sleep 1

# Audit assertions.
inbox_dms=$(audit_events_for_slug 'agents.*.inbox' "$TID" | grep -c '^.')
[ "$inbox_dms" -ge 4 ] && ok "AUDIT shows ≥4 inbox DMs ($inbox_dms)" \
  || bad "expected ≥4 inbox DMs, got $inbox_dms"

shipped_evt=$(audit_events_for_slug 'board.results.fullstack.shipped' "$TID")
echo "$shipped_evt" | grep -q '"paired_with"' \
  && ok "shipped event records paired_with" \
  || bad "shipped event missing paired_with: $shipped_evt"

summary
