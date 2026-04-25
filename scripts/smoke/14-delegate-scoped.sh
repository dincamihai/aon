#!/usr/bin/env bash
# Sim 14 — delegated with scope (e.g. terraform only); sim agent honors.
# Substrate cannot enforce scope (that's prompt's job); test verifies the
# delegation payload structure round-trips and is queryable.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 14 scoped delegation ──"

ROLE=diego
UNTIL=$(date -u -v+8H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d '+8 hours' +%Y-%m-%dT%H:%M:%SZ)

# Delegate diego for go domain only, expires in 8h.
PAYLOAD=$(jq -nc --arg u "$UNTIL" \
          '{status:"delegated", scope:["go"], until:$u, since:"'"$(ts_now)"'"}')
kv_put_raw "agent.$ROLE.human" "$PAYLOAD"
ok "delegated $ROLE for scope=[go] until=$UNTIL"

# Verify scope is queryable.
val=$(nats --server "$NATS_URL" --user sysadmin --password "$SMOKE_PASS" \
      kv get team-state "agent.$ROLE.human" --raw 2>/dev/null)
echo "$val" | jq -e '.scope | index("go")' >/dev/null 2>&1 \
  && ok "scope contains 'go'" || bad "scope missing 'go': $val"
echo "$val" | jq -e '.scope | index("terraform")' >/dev/null 2>&1 \
  && bad "scope unexpectedly contains 'terraform'" || ok "scope excludes terraform"

# Live event for subscribers.
sim_pub "state.agent.$ROLE.human" "$PAYLOAD" && ok "delegate event emitted"

# Restore.
kv_put_raw "agent.$ROLE.human" '{"status":"available","since":"'"$(ts_now)"'"}'

summary
