#!/usr/bin/env bash
# scripts/join.sh — shim. Use `aon join <role> <work-repo>` directly.
#
# Retained for one release so existing instructions don't break.
# The full implementation lives in `bin/aon` (cmd_join, Card 247).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AON_BIN="$SCRIPT_DIR/../bin/aon"

[[ -x "$AON_BIN" ]] || { echo "ERROR: $AON_BIN not executable" >&2; exit 1; }

echo "▸ scripts/join.sh is a shim — forwarding to: aon join $*" >&2
exec "$AON_BIN" join "$@"
