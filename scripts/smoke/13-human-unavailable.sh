#!/usr/bin/env bash
# Sim 13 — human flips to busy; substrate reflects state immediately.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"
source "$SMOKE_DIR/_sim_lib.sh"

echo "── 13 human availability (busy / offline / delegated) ──"

ROLE=lin

# Default available.
kv_put_raw "agent.$ROLE.human" '{"status":"available","since":"'"$(ts_now)"'"}'
val=$(nats --server "$NATS_URL" --creds "$SYSADMIN_CREDS" \
      kv get team-state "agent.$ROLE.human" --raw 2>/dev/null)
echo "$val" | grep -q '"status":"available"' && ok "default $ROLE.human=available" \
  || bad "default not available: $val"

# Flip busy + emit live state event.
kv_put_raw "agent.$ROLE.human" '{"status":"busy","since":"'"$(ts_now)"'","reason":"in meeting"}'
sim_pub "state.agent.$ROLE.human" '{"status":"busy","reason":"in meeting"}'
ok "flipped $ROLE.human to busy"

# Verify KV reads back busy.
val=$(nats --server "$NATS_URL" --creds "$SYSADMIN_CREDS" \
      kv get team-state "agent.$ROLE.human" --raw 2>/dev/null)
echo "$val" | grep -q '"status":"busy"' && ok "$ROLE.human reads busy" \
  || bad "expected busy, got: $val"

# Flip offline.
kv_put_raw "agent.$ROLE.human" '{"status":"offline","since":"'"$(ts_now)"'"}'
val=$(nats --server "$NATS_URL" --creds "$SYSADMIN_CREDS" \
      kv get team-state "agent.$ROLE.human" --raw 2>/dev/null)
echo "$val" | grep -q '"status":"offline"' && ok "$ROLE.human=offline ok" \
  || bad "expected offline, got: $val"

# Restore.
kv_put_raw "agent.$ROLE.human" '{"status":"available","since":"'"$(ts_now)"'"}'

summary
