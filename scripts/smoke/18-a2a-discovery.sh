#!/usr/bin/env bash
# Smoke 18 — A2A discovery (slice 2 card 135).
#
# Validates: workers can publish own card to a2a.discovery.<self>;
# A2A_DISC enforces max-msgs-per-subject=1 (latest only); readers
# (e.g. maya) get the latest card.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 18 A2A discovery ──"

# 1. Each worker publishes own card from agents/<role>.json.
for role in raj lin sam diego priya; do
  card="$REPO_ROOT/agents/$role.json"
  [ -f "$card" ] || { bad "missing $card"; continue; }
  body=$(cat "$card")
  if nats_as "$role" pub "a2a.discovery.$role" "$body" >/dev/null 2>&1; then
    ok "$role published own discovery card"
  else
    bad "$role failed to publish own discovery card"
  fi
done

# Maya can also publish her own.
nats_as maya pub "a2a.discovery.maya" "$(cat "$REPO_ROOT/agents/maya.json")" >/dev/null 2>&1 \
  && ok "maya published own discovery card" \
  || bad "maya failed to publish own card"

# 2. Cross-role publish denied: lin cannot publish a2a.discovery.priya.
assert_pub_denied lin "a2a.discovery.priya" '{"name":"x"}'
assert_pub_denied sam "a2a.discovery.raj"   '{"name":"x"}'

# 3. Re-publish — A2A_DISC max-msgs-per-subject=1 means stream retains
# only latest. Publish twice, then check via stream subjects info.
nats_as priya pub "a2a.discovery.priya" '{"name":"priya","version":"0.1"}' >/dev/null 2>&1
nats_as priya pub "a2a.discovery.priya" '{"name":"priya","version":"0.2"}' >/dev/null 2>&1
sleep 0.5
cnt=$(nats_as sysadmin stream subjects A2A_DISC 2>/dev/null \
      | grep -c "a2a.discovery.priya │ 1" || true)
if [ "$cnt" -ge 1 ]; then
  ok "A2A_DISC retains only latest card per subject (priya count=1)"
else
  bad "expected 1 msg for a2a.discovery.priya, got cnt=$cnt"
fi

# 4. Latest content is the second publish (version 0.2).
cname="dbg-$$-$(date +%s%N)"
nats_as sysadmin consumer add A2A_DISC "$cname" --filter "a2a.discovery.priya" \
  --pull --deliver=last --ack=none --replay=instant --ephemeral --defaults >/dev/null 2>&1
last=$(nats_as sysadmin --timeout 1s consumer next A2A_DISC "$cname" --count 1 --raw --wait 500ms 2>/dev/null)
nats_as sysadmin consumer rm A2A_DISC "$cname" -f >/dev/null 2>&1
if echo "$last" | grep -q '"version":"0.2"'; then
  ok "A2A_DISC last msg is most recent publish"
else
  bad "expected version 0.2 retained; got: $last"
fi

# Restore priya's real card.
nats_as priya pub "a2a.discovery.priya" "$(cat "$REPO_ROOT/agents/priya.json")" >/dev/null 2>&1

# 5. Card structure assertions.
for role in maya raj lin sam diego priya; do
  card="$REPO_ROOT/agents/$role.json"
  name=$(jq -r .name "$card")
  ver=$(jq -r .version "$card")
  skills=$(jq -r '.skills | length' "$card")
  if [ "$name" = "$role" ] && [ -n "$ver" ]; then
    if [ "$role" = "maya" ] || [ "$skills" -gt 0 ]; then
      ok "$role card valid (name=$name version=$ver skills=$skills)"
    else
      bad "$role card has empty skills"
    fi
  else
    bad "$role card name/version mismatch"
  fi
done

summary
