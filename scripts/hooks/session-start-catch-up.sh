#!/usr/bin/env bash
# SessionStart hook — replay queued events since last cursor.
# Cursor file: ~/.aon/teams/<team>/cursors/last-seen-<role>  (ISO timestamp)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

# Read cursor; default 1h lookback if missing.
SINCE=""
if [ -s "$HOOK_CURSOR_FILE" ]; then
  ISO="$(tr -d '[:space:]' < "$HOOK_CURSOR_FILE")"
  # nats sub --since accepts duration ('1h') OR start-time ('--start-time=ISO').
  # Use --start-time for deterministic catch-up.
  SINCE="--start-time=$ISO"
else
  SINCE="--since=1h"
fi

# Gather events from each subscribed subject (best-effort; per-subject
# timeout 1.5s, capped at 50 msgs total).
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

COUNT=0
while IFS= read -r subj; do
  [ "$COUNT" -ge 50 ] && break
  remaining=$((50 - COUNT))
  out=$(nats_role sub "$subj" $SINCE --count "$remaining" --wait 1.5s --raw 2>/dev/null) || true
  [ -z "$out" ] && continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\t%s\n' "$subj" "$line" >> "$TMP"
    COUNT=$((COUNT + 1))
    [ "$COUNT" -ge 50 ] && break
  done <<< "$out"
done < <(hook_role_subjects)

# Bump cursor regardless (avoid replaying same events forever).
echo -n "$(now_iso)" > "$HOOK_CURSOR_FILE"

[ "$COUNT" -eq 0 ] && exit 0

# Format summary.
SUMMARY=$(awk -F'\t' '{
  subj=$1; payload=$2
  print "[" subj "] " payload
}' "$TMP" | head -50)

CTX="aon catch-up: $COUNT queued event(s) since last session.

$SUMMARY

Cursor advanced. If you need full replay use: nats sub <subject> --start-time=<iso>"

jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
