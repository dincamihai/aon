#!/usr/bin/env bash
# Scenario 04 — incident: Priya broadcasts, Raj DMs offer, Priya resolves.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SIM_DIR/_lib.sh"

echo "── scenario 04: incident broadcast + collaboration (priya, raj) ──"

INCIDENT="inc-$(date +%s%N)"

# Priya broadcasts incident.
incident_open=$(jq -nc --arg i "$INCIDENT" --arg t "$(ts_now)" \
  '{incident_id:$i, slug:$i, severity:"high", system:"staging-vpc",
    owner:"priya", status:"investigating", ts:$t}')
as_role priya pub "broadcast.incidents" "$incident_open" >/dev/null 2>&1 \
  && ok "priya broadcast incident $INCIDENT investigating" \
  || bad "priya broadcast failed"

# Raj DMs offer of help.
offer=$(jq -nc --arg i "$INCIDENT" --arg t "$(ts_now)" \
  '{type:"help_offer", from:"raj", incident_id:$i, slug:$i,
    expertise:"route tables", ts:$t}')
dm_to_inbox raj priya "$offer" && ok "raj DM priya offering help"

# Priya replies asking for specific check.
ask=$(jq -nc --arg i "$INCIDENT" --arg t "$(ts_now)" \
  '{type:"help_request", from:"priya", incident_id:$i, slug:$i,
    request:"check route tables on rt-12ab", ts:$t}')
dm_to_inbox priya raj "$ask" && ok "priya DM raj specific check"

# Priya resolves.
incident_close=$(jq -nc --arg i "$INCIDENT" --arg t "$(ts_now)" \
  '{incident_id:$i, slug:$i, severity:"high", system:"staging-vpc",
    owner:"priya", status:"resolved",
    root_cause:"missing route table assoc after recent change", ts:$t}')
as_role priya pub "broadcast.incidents" "$incident_close" >/dev/null 2>&1 \
  && ok "priya broadcast incident resolved" || bad "broadcast resolved failed"

sleep 1

# Audit: 2 broadcasts (open+close) + 2 inbox DMs.
broadcasts=$(audit_events_for_slug 'broadcast.incidents' "$INCIDENT" | grep -c '^.')
[ "$broadcasts" -eq 2 ] && ok "AUDIT records 2 incident broadcasts" \
  || bad "expected 2 broadcasts, got $broadcasts"

dms=$(audit_events_for_slug 'agents.*.inbox' "$INCIDENT" | grep -c '^.')
[ "$dms" -ge 2 ] && ok "AUDIT records ≥2 inbox DMs ($dms)" \
  || bad "expected ≥2 DMs, got $dms"

# Final state of incident must be resolved.
last=$(audit_events_for_slug 'broadcast.incidents' "$INCIDENT" | tail -1)
echo "$last" | grep -q '"status":"resolved"' \
  && ok "last incident broadcast = resolved (root_cause captured)" \
  || bad "last broadcast not resolved: $last"

summary
