#!/usr/bin/env bash
# Live shadow validation — sample a fraction of audit-stream verdicts
# and ask the judge if the classifier got them right. Tracks
# disagreement rate; alerts on drift.
#
# Subscribes to evt.security.gate.> on the operator's NATS creds
# (sysadmin or AON_SECURITY_OPERATOR override). Disagreements are
# appended to ~/.aon/security/evolve/shadow.jsonl with a 24h rolling
# window summarised in shadow-rate.json.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/_lib.sh"

SHADOW_RATE="${AON_GATE_SHADOW_RATE:-0.01}"           # fraction of verdicts to judge
SHADOW_DISAGREE_THRESHOLD="${AON_GATE_SHADOW_THRESHOLD:-0.05}"
SHADOW_AUTO_EVOLVE="${AON_GATE_SHADOW_AUTO_EVOLVE:-0}"

SHADOW_LOG="$EVOLVE_DIR/shadow.jsonl"
SHADOW_RATE_FILE="$EVOLVE_DIR/shadow-rate.json"

NATS_URL="${AON_NATS_URL:-nats://localhost:4222}"
NATS_CREDS="${AON_CREDS:-}"
ROLE="${AON_ROLE:-sysadmin}"

[ -r "$NATS_CREDS" ] || {
  evolve_log ERROR "AON_CREDS unreadable: '$NATS_CREDS' (run via 'aon security shadow start')"
  exit 1
}
command -v nats >/dev/null || { evolve_log ERROR "nats CLI missing"; exit 1; }

evolve_log INFO "shadow: sampling $SHADOW_RATE of evt.security.gate.> as $ROLE"

# Reservoir state (global)
total=0
sampled=0
agree=0
false_allow=0   # classifier=allow, judge=deny — high severity
false_deny=0    # classifier=deny, judge=allow — UX irritant

emit_rate() {
  jq -nc \
    --argjson total "$total" \
    --argjson sampled "$sampled" \
    --argjson agree "$agree" \
    --argjson fa "$false_allow" \
    --argjson fd "$false_deny" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ts:$ts, total:$total, sampled:$sampled, agree:$agree,
      false_allow:$fa, false_deny:$fd,
      disagreement_rate: (if $sampled>0 then (($fa+$fd)/$sampled) else 0 end)}' \
    >"$SHADOW_RATE_FILE"
}

handle_audit() {
  local line="$1"
  total=$((total + 1))
  # Random sample at SHADOW_RATE
  awk -v r="$SHADOW_RATE" 'BEGIN{srand(); exit !(rand() < r)}' || return 0
  sampled=$((sampled + 1))

  local argv c_verdict
  argv=$(printf '%s' "$line" | jq -r '.argv // empty')
  c_verdict=$(printf '%s' "$line" | jq -r '.verdict // empty')
  [ -z "$argv" ] && return 0
  # Skip layers that aren't really "classifier" calls (cache/regex pre-filter trivial)
  local layer; layer=$(printf '%s' "$line" | jq -r '.layer // ""')
  case "$layer" in
    cache|allow.regex|allow.local|deny.regex|deny.local|bypass) return 0 ;;
  esac

  # Ask judge: classifier said X, what does the judge think?
  local req
  req=$(jq -nc --arg argv "$argv" --arg cv "$c_verdict" \
    '{argv:$argv, verdicts:[
        {prompt_id:"a", verdict:$cv, reason:"current classifier"},
        {prompt_id:"b", verdict:(if $cv=="allow" then "deny" else "allow" end),
         reason:"hypothetical opposite"}
      ]}')
  local judgement; judgement=$(printf '%s' "$req" | bash "$HERE/judge.sh" 2>/dev/null) || return 0
  local correct; correct=$(printf '%s' "$judgement" | jq -r '.correct // ""')

  if [ "$correct" = "$c_verdict" ]; then
    agree=$((agree + 1))
  else
    if [ "$c_verdict" = "allow" ]; then
      false_allow=$((false_allow + 1))
    else
      false_deny=$((false_deny + 1))
    fi
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg argv "$argv" \
           --arg c "$c_verdict" \
           --arg j "$correct" \
           --arg crit "$(printf '%s' "$judgement" | jq -r '.critique // ""')" \
      '{ts:$ts, argv:$argv, classifier:$c, judge:$j, critique:$crit}' \
      >>"$SHADOW_LOG"
  fi

  emit_rate

  # Alert + optional auto-evolve when threshold crossed
  if [ "$sampled" -ge 20 ]; then
    local rate
    rate=$(awk -v fa="$false_allow" -v fd="$false_deny" -v s="$sampled" \
      'BEGIN{ printf "%.4f", (fa+fd)/s }')
    if awk -v r="$rate" -v t="$SHADOW_DISAGREE_THRESHOLD" \
        'BEGIN{ exit !(r+0 > t+0) }'; then
      evolve_log WARN "shadow drift: $rate > $SHADOW_DISAGREE_THRESHOLD (false_allow=$false_allow false_deny=$false_deny over $sampled)"
      nats --server "$NATS_URL" --creds "$NATS_CREDS" pub \
        "evt.security.gate.drift-alert.$ROLE" \
        "$(jq -nc --arg r "$rate" --argjson fa "$false_allow" --argjson fd "$false_deny" \
            '{rate:$r, false_allow:$fa, false_deny:$fd}')" \
        >/dev/null 2>&1 || true
      if [ "$SHADOW_AUTO_EVOLVE" = "1" ]; then
        evolve_log INFO "shadow auto-evolve: kicking off one round"
        ( python3 "$HERE/evolve.py" --rounds 1 --argv 20 --candidates 4 >"$EVOLVE_DIR/auto-evolve.log" 2>&1 & )
      fi
    fi
  fi
}

# Stream the audit subject; one JSON object per --raw line
nats --server "$NATS_URL" --creds "$NATS_CREDS" sub --raw \
  "evt.security.gate.>" 2>/dev/null \
  | while IFS= read -r line; do
      handle_audit "$line"
    done
