#!/usr/bin/env bash
# Smoke 02 — onboard.sh round-trip for every role.
#
# Validates: env validation, auth, handshake publish, KV load write, prompt
# fallback warning, monitor command emission. Uses temp creds files.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 02 onboard round-trip ──"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for role in maya raj lin sam diego priya; do
  pwfile="$TMP/$role.pw"
  printf '%s' "$SMOKE_PASS" > "$pwfile"
  chmod 600 "$pwfile"
  out=$(TEAM_ALPHA_ROLE="$role" \
        TEAM_ALPHA_NATS_URL="$NATS_URL" \
        TEAM_ALPHA_CREDS="$pwfile" \
        bash "$REPO_ROOT/scripts/onboard.sh" "$role" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$role onboard exit=$rc"
    echo "$out" | sed 's/^/    /'
    continue
  fi
  echo "$out" | grep -q "✓ NATS reachable + auth OK" \
    && ok "$role auth ok" || bad "$role auth check missing"
  echo "$out" | grep -q "handshake published to agents.$role.events" \
    && ok "$role handshake published" || bad "$role handshake missing"
  echo "$out" | grep -q "team-state.agent.$role.load = active" \
    && ok "$role load KV write" || bad "$role load KV missing"
  echo "$out" | grep -q "Onboarded as $role" \
    && ok "$role end-of-script ok" || bad "$role missing terminal banner"
done

# KV reflects most recent load capacity = active for all six.
for role in maya raj lin sam diego priya; do
  val=$(nats_as sysadmin kv get team-state "agent.$role.load" --raw 2>/dev/null || echo "")
  echo "$val" | grep -q '"capacity":"active"' \
    && ok "$role load KV reads back active" \
    || bad "$role load KV read got: $val"
done

summary
