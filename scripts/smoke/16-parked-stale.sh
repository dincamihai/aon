#!/usr/bin/env bash
# Smoke 16 — coordinator-watcher detects stale parked entry.
# Inject KV parked entry with backdated `since`; run watcher with low
# PARKED_STALE_SEC; expect state.alert.parked_stale.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 16 parked-stale alert ──"

ROLE=raj
SLUG="parked-stale-$(date +%s%N)"
# 5 seconds ago (BSD/GNU date compat).
TS=$(date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
   || date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ)

STACK=$(jq -nc --arg s "$SLUG" --arg t "$TS" --arg b "feature/$SLUG" \
        '[{slug:$s, branch:$b, since:$t}]')
echo -n "$STACK" \
  | nats_as sysadmin kv put team-state "agent.$ROLE.parked" >/dev/null 2>&1 \
  && ok "wrote stale parked entry for $ROLE ($SLUG, 5s ago)"

# Run watcher with PARKED_STALE_SEC=2 → backdated 5s qualifies as stale.
ALERTS=$(PARKED_STALE_SEC=2 NATS_URL="$NATS_URL" \
         NATS_ADMIN_USER=sysadmin NATS_ADMIN_PASSWORD="$SMOKE_PASS" \
         bash "$SMOKE_DIR/../coordinator-watcher.sh" tick 2>&1 | grep '^ALERT:' || true)

if echo "$ALERTS" | grep -q "parked_stale.*$SLUG"; then
  ok "watcher emitted parked_stale for $SLUG"
else
  bad "no parked_stale alert for $SLUG"
  echo "$ALERTS" | head -5 | sed 's/^/    /' >&2
fi

# Restore: clear parked KV.
echo -n '[]' | nats_as sysadmin kv put team-state "agent.$ROLE.parked" >/dev/null 2>&1

summary
