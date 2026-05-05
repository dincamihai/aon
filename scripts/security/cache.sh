#!/usr/bin/env bash
# Verdict cache. Maps sha256(argv) → JSON {verdict,category,reason,ts}.
# Hit returns the JSON on stdout; miss returns non-zero.
# Usage:
#   cache.sh get  <hash>       → prints JSON, exit 0 on hit
#   cache.sh put  <hash> <json>
#   cache.sh clear

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/_lib.sh"

action="${1:-}"
case "$action" in
  get)
    h="${2:-}"; [ -n "$h" ] || exit 2
    f="$GATE_CACHE_DIR/$h"
    [ -f "$f" ] || exit 1
    ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - ts))
    if [ "$age" -gt "$GATE_CACHE_TTL" ]; then
      rm -f "$f"
      exit 1
    fi
    cat "$f"
    ;;
  put)
    h="${2:-}"; json="${3:-}"
    [ -n "$h" ] && [ -n "$json" ] || exit 2
    printf '%s' "$json" >"$GATE_CACHE_DIR/$h"
    ;;
  clear)
    rm -rf "$GATE_CACHE_DIR"
    mkdir -p "$GATE_CACHE_DIR"
    ;;
  *)
    echo "usage: cache.sh {get <hash>|put <hash> <json>|clear}" >&2
    exit 2
    ;;
esac
