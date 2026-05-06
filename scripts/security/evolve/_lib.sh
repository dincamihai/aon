#!/usr/bin/env bash
# Shared helpers for cmd-gate evolve scripts. Sourced; do not exec.

set -u

EVOLVE_DIR="${AON_GATE_EVOLVE_DIR:-$HOME/.aon/security/evolve}"
SPEND_LOG="$EVOLVE_DIR/spend.log"
mkdir -p "$EVOLVE_DIR" 2>/dev/null || true

# Backends: anthropic | ollama
EVOLVE_BACKEND="${AON_GATE_EVOLVE_BACKEND:-anthropic}"

# Models — defaults differ per backend
case "$EVOLVE_BACKEND" in
  anthropic) EVOLVE_MODEL="${AON_GATE_EVOLVE_MODEL:-claude-opus-4-7-20251001}" ;;
  ollama)    EVOLVE_MODEL="${AON_GATE_EVOLVE_MODEL:-gpt-oss:20b}" ;;
  *) echo "evolve: unknown backend '$EVOLVE_BACKEND' (expected anthropic|ollama)" >&2; exit 2 ;;
esac

EVOLVE_OLLAMA_URL="${AON_GATE_EVOLVE_OLLAMA_URL:-http://127.0.0.1:11434}"
EVOLVE_TIMEOUT_S="${AON_GATE_EVOLVE_TIMEOUT_S:-30}"
EVOLVE_BUDGET_USD="${AON_GATE_EVOLVE_BUDGET_USD:-20}"

evolve_log() {
  local level="$1"; shift
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s %s\n' "$ts" "$level" "$*" >&2
}

# Pricing per 1M tokens (USD). Update as Anthropic pricing changes.
# Used for spend log + budget guard.
_evolve_price_in() {
  case "$1" in
    claude-opus-4-7*)        echo "15" ;;
    claude-sonnet-4-6*)      echo "3" ;;
    claude-haiku-4-5*)       echo "0.80" ;;
    *)                       echo "0" ;;
  esac
}
_evolve_price_out() {
  case "$1" in
    claude-opus-4-7*)        echo "75" ;;
    claude-sonnet-4-6*)      echo "15" ;;
    claude-haiku-4-5*)       echo "4" ;;
    *)                       echo "0" ;;
  esac
}

# Append spend record. Args: model in_tok out_tok
evolve_record_spend() {
  local model="$1" in_tok="$2" out_tok="$3"
  if [ "$EVOLVE_BACKEND" = "ollama" ]; then
    return 0   # local, no $ cost
  fi
  local pin pout cost
  pin="$(_evolve_price_in "$model")"
  pout="$(_evolve_price_out "$model")"
  cost="$(awk -v in_t="$in_tok" -v out_t="$out_tok" -v pi="$pin" -v po="$pout" \
    'BEGIN{ printf "%.6f", (in_t * pi + out_t * po) / 1000000 }')"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model" "$in_tok" "$out_tok" "$cost" \
    >>"$SPEND_LOG"
}

# Cumulative spend in current calendar day. Reads SPEND_LOG.
evolve_today_spend_usd() {
  [ -f "$SPEND_LOG" ] || { echo "0"; return; }
  local today; today="$(date -u +%Y-%m-%d)"
  awk -v t="$today" -F'\t' '$1 ~ t { sum += $5 } END { printf "%.4f", sum+0 }' "$SPEND_LOG"
}

# Refuse if today's spend would exceed budget.
evolve_check_budget() {
  [ "$EVOLVE_BACKEND" = "ollama" ] && return 0
  local spent budget
  spent="$(evolve_today_spend_usd)"
  budget="$EVOLVE_BUDGET_USD"
  if awk -v s="$spent" -v b="$budget" 'BEGIN{ exit !(s+0 >= b+0) }'; then
    evolve_log ERROR "budget exhausted: today=\$$spent budget=\$$budget"
    return 1
  fi
  return 0
}

# Call Anthropic API. Args: system prompt, user prompt.
# Stdout: response text (assistant content). Records spend.
evolve_call_anthropic() {
  local system="$1" user="$2"
  local key="${ANTHROPIC_API_KEY:-}"
  [ -n "$key" ] || { evolve_log ERROR "ANTHROPIC_API_KEY unset"; return 1; }
  evolve_check_budget || return 1

  local req
  req=$(jq -nc \
    --arg model "$EVOLVE_MODEL" \
    --arg system "$system" \
    --arg user "$user" \
    '{model:$model, max_tokens:1024, system:$system,
      messages:[{role:"user", content:$user}]}')

  local resp
  resp=$(curl -sS --max-time "$EVOLVE_TIMEOUT_S" \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    https://api.anthropic.com/v1/messages \
    -d "$req" 2>/dev/null) || {
      evolve_log ERROR "anthropic call failed (network/timeout)"
      return 1
    }

  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    evolve_log ERROR "anthropic error: $(echo "$resp" | jq -r .error.message)"
    return 1
  fi

  local text in_tok out_tok
  text="$(echo "$resp" | jq -r '.content[0].text // empty')"
  in_tok="$(echo "$resp" | jq -r '.usage.input_tokens // 0')"
  out_tok="$(echo "$resp" | jq -r '.usage.output_tokens // 0')"
  evolve_record_spend "$EVOLVE_MODEL" "$in_tok" "$out_tok"

  printf '%s' "$text"
}

# Call ollama generate. Args: system prompt, user prompt.
# Stdout: response text.
evolve_call_ollama() {
  local system="$1" user="$2"
  local req
  req=$(jq -nc \
    --arg model "$EVOLVE_MODEL" \
    --arg system "$system" \
    --arg user "$user" \
    '{model:$model, system:$system, prompt:$user, stream:false,
      format:"json", keep_alive:"24h",
      options:{temperature:0, num_predict:1024}}')

  local resp
  resp=$(curl -sS --max-time "$EVOLVE_TIMEOUT_S" \
    "$EVOLVE_OLLAMA_URL/api/generate" -d "$req" 2>/dev/null) || {
      evolve_log ERROR "ollama call failed"
      return 1
    }

  echo "$resp" | jq -r '.response // empty'
}

# Backend-agnostic LLM call. Args: system prompt, user prompt.
evolve_call_llm() {
  case "$EVOLVE_BACKEND" in
    anthropic) evolve_call_anthropic "$@" ;;
    ollama)    evolve_call_ollama "$@" ;;
  esac
}
