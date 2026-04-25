#!/usr/bin/env bash
# Run all scenarios sequentially. Non-zero exit if any fail.
set -u
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERALL=0
for s in "$SIM_DIR"/scenario-*.sh; do
  echo
  bash "$s" || OVERALL=1
done
echo
if [ "$OVERALL" -eq 0 ]; then
  echo "═══ ALL SCENARIOS PASS ═══"
else
  echo "═══ SCENARIO FAILURES ═══" >&2
fi
exit "$OVERALL"
