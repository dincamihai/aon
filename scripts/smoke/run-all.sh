#!/usr/bin/env bash
# Smoke harness — run every assertion, return non-zero if any fail.
#
# Usage:
#   bash scripts/smoke/run-all.sh                      # against running stack
#   NATS_URL=nats://other:4222 bash run-all.sh
#   SMOKE_PASS=<real-pw> bash run-all.sh               # if not devpass
#
# Prereq: stack up + bootstrap done. See scripts/smoke/README.md.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OVERALL=0
for t in "$SMOKE_DIR"/[0-9]*.sh; do
  echo
  bash "$t" || OVERALL=1
done

echo
if [ "$OVERALL" -eq 0 ]; then
  echo "═══ ALL SMOKE TESTS PASS ═══"
else
  echo "═══ SMOKE TESTS FAILED ═══" >&2
fi
exit "$OVERALL"
