#!/usr/bin/env bash
# Publish a verdict audit envelope to NATS.
# Usage: audit.sh <argv> <verdict> <category> <reason> <layer>
# Best-effort: failures here never block the gate.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/_lib.sh"

argv="${1:-}"; verdict="${2:-}"; category="${3:-}"; reason="${4:-}"; layer="${5:-}"

# Always log locally.
gate_log "AUDIT" "verdict=$verdict layer=$layer category=$category argv=$argv"

role="${AON_ROLE:-unknown}"
team="${AON_TEAM:-team-alpha}"
url="${AON_NATS_URL:-}"
creds="${AON_CREDS:-}"

# If no NATS context, fall back to local log only.
[ -n "$url" ] && [ -n "$creds" ] && [ -r "$creds" ] || exit 0
command -v nats >/dev/null 2>&1 || exit 0

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
payload=$(jq -nc \
  --arg ts "$ts" --arg role "$role" --arg argv "$argv" \
  --arg verdict "$verdict" --arg category "$category" \
  --arg reason "$reason" --arg layer "$layer" \
  '{ts:$ts, role:$role, argv:$argv, verdict:$verdict,
    category:$category, reason:$reason, layer:$layer}')

# Subject: evt.security.gate.<role>
nats --server "$url" --creds "$creds" pub \
  "evt.security.gate.$role" "$payload" >/dev/null 2>&1 || true
