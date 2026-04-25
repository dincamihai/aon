#!/usr/bin/env bash
# Scenario 05 — mentoring: Raj offers Go mentoring; Lin DMs to grab slot;
# Raj posts learning task; Lin claims + ships.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 05: mentoring offer + uptake (raj → lin on go) ──"

OFFER_ID="mentor-$(date +%s%N)"

# Raj offers Go mentoring.
offer=$(jq -nc --arg i "$OFFER_ID" --arg t "$(ts_now)" \
  '{slug:$i, mentor:"raj", domain:"go", hours:4,
    topics:["concurrency","interfaces"], ts:$t}')
as_role raj pub "board.learning.go.mentoring" "$offer" >/dev/null 2>&1 \
  && ok "raj offered go mentoring" || bad "offer failed"

# Lin DMs to grab slot.
ack=$(jq -nc --arg t "$(ts_now)" \
  '{type:"mentor_signup", from:"lin", domain:"go",
    topic:"concurrency", ts:$t}')
dm_to_inbox lin raj "$ack" && ok "lin DM raj signing up"

# Raj posts learning task scoped to mentoring.
LTID="learn-go-$(date +%s%N)"
learn=$(jq -nc --arg s "$LTID" --arg t "$(ts_now)" \
  '{task_id:$s, slug:$s, summary:"refactor worker pool to chan",
    priority:"low", ts:$t, by:"raj", scope_hours:4, mentor:"raj"}')
as_role raj pub "board.learning.go.pending" "$learn" >/dev/null 2>&1 \
  && ok "raj posted learning task $LTID" || bad "post failed"

# Lin claims learning (allowed).
lin_claim=$(jq -nc --arg s "$LTID" --arg t "$(ts_now)" '{slug:$s, by:"lin", ts:$t}')
as_role lin pub "board.learning.go.claimed" "$lin_claim" >/dev/null 2>&1 \
  && ok "lin claimed learning go" || bad "lin claim denied"

sleep 1

# AUDIT verifications.
mentoring=$(audit_events_for_slug 'board.learning.go.mentoring' "$OFFER_ID" \
            | jq -r '.mentor' 2>/dev/null | tr -d '\n')
[ "$mentoring" = "raj" ] && ok "AUDIT shows raj as mentor" \
  || bad "expected raj mentor, got '$mentoring'"

claim_by=$(audit_events_for_slug 'board.learning.go.claimed' "$LTID" \
           | jq -r '.by' 2>/dev/null | tr -d '\n')
[ "$claim_by" = "lin" ] && ok "AUDIT shows lin claimed learning go" \
  || bad "expected lin claimer, got '$claim_by'"

# Sanity: Sam ALSO subscribes to board.learning.go.mentoring; could've grabbed.
# Just confirm offer was visible — no test on it (live multi-agent race not
# applicable in scripted sim).

summary
