#!/usr/bin/env bash
# Smoke 22 — KV agent.<role>.skills deprecation (slice 2 card 136).
#
# Verifies:
#   - agents/<role>.json parseable for each role
#   - agents/<role>.json non-empty skills (workers) / empty (manager)
#   - KV team-state.agent.<role>.skills returns nothing post-migration
#   - migration script idempotent
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 22 skills source of truth ──"

# 1. agents/<role>.json parseable.
for role in maya raj lin sam diego priya; do
  card="$REPO_ROOT/agents/$role.json"
  if jq . "$card" >/dev/null 2>&1; then
    ok "$role card parseable"
  else
    bad "$role card not parseable: $card"
  fi
done

# 2. Worker cards have skills; manager card is empty.
for role in raj lin sam diego priya; do
  n=$(jq '.skills | length' "$REPO_ROOT/agents/$role.json")
  [ "$n" -gt 0 ] && ok "$role card skills ($n)" || bad "$role card empty"
done
n=$(jq '.skills | length' "$REPO_ROOT/agents/maya.json")
[ "$n" = "0" ] && ok "maya card has no skills (manager)" \
  || bad "maya card unexpectedly has $n skills"

# 3. KV agent.<role>.skills must NOT exist.
for role in maya raj lin sam diego priya; do
  out=$(nats_as sysadmin kv get team-state "agent.$role.skills" --raw 2>&1 || true)
  if echo "$out" | grep -qiE "no entry|not found|key not found"; then
    ok "KV agent.$role.skills absent (deprecated)"
  elif [ -z "$(echo "$out" | tr -d '[:space:]')" ]; then
    ok "KV agent.$role.skills empty/absent (deprecated)"
  else
    bad "KV agent.$role.skills still present: $out"
  fi
done

# 4. Migration script idempotent.
out=$(NATS_URL="$NATS_URL" NATS_ADMIN_CREDS="$SYSADMIN_CREDS" \
      bash "$REPO_ROOT/scripts/migrate-2026-04-skills-kv.sh" 2>&1 | tail -1)
if echo "$out" | grep -q "removed=0"; then
  ok "migration script idempotent on second run"
else
  bad "migration not idempotent: $out"
fi

# 5. Loader returns the same skills as the json file (a2a.cards module).
PY="${PY:-/Users/mid/Repos/ai-over-nats/mcp-server/.venv/bin/python}"
[ -x "$PY" ] || PY=python3
res=$(cd "$REPO_ROOT/mcp-server" && PYTHONPATH=src "$PY" -c "
from team_alpha_mcp.a2a import cards
import json
for r in ['raj','lin','priya']:
    c = cards.load_card(r)
    print(r, sorted(s['id'] for s in c['skills']))
" 2>&1)
echo "$res" | grep -q "raj \['aws', 'fullstack'" && ok "cards.load_card returns expected skills" \
  || bad "cards.load_card unexpected: $res"

summary
