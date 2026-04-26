#!/usr/bin/env bash
# Coordinator-watcher — scans recent events, emits state.alert.<kind>
# when invariants are violated. Tick-based, deterministic. Run as sysadmin.
#
# Modes:
#   tick    — scan once, emit alerts, exit. Used by sim/smoke.
#   serve   — loop tick every $WATCHER_INTERVAL sec. Used in real ops.
#
# Detected conditions:
#   duplicate_claim   — two roles published board.tasks.*.claimed for same slug
#   duplicate_result  — two roles shipped same slug
#   stale_claim       — claimed >$STALE_CLAIM_SEC ago, no done/result
#   parked_stale      — parked entry older than $PARKED_STALE_SEC
#   no_human          — agent emitted no_human alert (relayed)
#
# Required env: NATS_URL, NATS_ADMIN_USER, NATS_ADMIN_PASSWORD
set -u
: "${NATS_URL:?}"
: "${NATS_ADMIN_USER:=sysadmin}"
: "${NATS_ADMIN_PASSWORD:?}"
: "${WATCHER_LOOKBACK:=10m}"
: "${STALE_CLAIM_SEC:=300}"
: "${PARKED_STALE_SEC:=900}"
: "${WATCHER_INTERVAL:=30}"

NATS_BIN="${NATS_BIN:-nats}"
: "${WATCHER_NATS_TIMEOUT:=2s}"
nats_admin() {
  "$NATS_BIN" --timeout "$WATCHER_NATS_TIMEOUT" \
    --server "$NATS_URL" --user "$NATS_ADMIN_USER" --password "$NATS_ADMIN_PASSWORD" "$@"
}

emit_alert() {
  local kind="$1" payload="$2"
  nats_admin pub "state.alert.$kind" "$payload" >/dev/null 2>&1
  echo "ALERT: state.alert.$kind $payload"
}

# Pull recent messages from AUDIT filtered by subject pattern.
# Ephemeral consumer bounded to WATCHER_LOOKBACK (e.g. 10m) so the scan
# is cheap regardless of AUDIT history size. Without the bound, a bloated
# AUDIT (1k+ msgs) makes consumer-next-with-count run for minutes per call.
recent_msgs() {
  local subject="$1"
  local cname="watcher-$$-$(date +%s%N)-$RANDOM"
  nats_admin consumer add AUDIT "$cname" \
    --filter "$subject" --pull --deliver="$WATCHER_LOOKBACK" --ack=none \
    --replay=instant --ephemeral --defaults >/dev/null 2>&1 || return 0
  nats_admin consumer next AUDIT "$cname" --count 500 --raw --wait 1s 2>/dev/null || true
  nats_admin consumer rm AUDIT "$cname" -f >/dev/null 2>&1 || true
}

tick() {
  local now claims_file results_file parked_file
  now=$(date +%s)
  claims_file=$(mktemp); results_file=$(mktemp); parked_file=$(mktemp)
  trap 'rm -f "$claims_file" "$results_file" "$parked_file"' RETURN

  # Collect claim events.
  recent_msgs 'board.tasks.*.claimed' \
    | jq -c 'select(.slug != null) | {slug, by:(.by // .role // .from), ts}' 2>/dev/null \
    > "$claims_file" || true

  # Duplicate-claim detection: same slug claimed by 2+ distinct `by`.
  if [ -s "$claims_file" ]; then
    jq -s 'group_by(.slug) | map(select((map(.by) | unique | length) > 1))
                           | .[]' "$claims_file" 2>/dev/null \
    | jq -c '.[0] as $first | {slug:$first.slug, claimers:(map(.by) | unique)}' 2>/dev/null \
    | while read -r dup; do
        emit_alert duplicate_claim "$dup"
      done
  fi

  # Collect result/shipped events.
  recent_msgs 'board.results.>' \
    | jq -c 'select(.slug != null) | {slug, by:(.by // .role // .from), ts}' 2>/dev/null \
    > "$results_file" || true

  if [ -s "$results_file" ]; then
    jq -s 'group_by(.slug) | map(select((map(.by) | unique | length) > 1)) | .[]' \
        "$results_file" 2>/dev/null \
    | jq -c '.[0] as $first | {slug:$first.slug, shippers:(map(.by) | unique)}' 2>/dev/null \
    | while read -r dup; do
        emit_alert duplicate_result "$dup"
      done
  fi

  # Stale-claim: slug claimed > STALE_CLAIM_SEC ago, no done event.
  if [ -s "$claims_file" ]; then
    # Build set of done slugs.
    done_slugs=$(recent_msgs 'board.tasks.*.done' \
                 | jq -r 'select(.slug) | .slug' 2>/dev/null | sort -u)
    while read -r line; do
      slug=$(echo "$line" | jq -r '.slug')
      ts=$(echo "$line"   | jq -r '.ts // empty')
      [ -z "$slug" ] && continue
      if echo "$done_slugs" | grep -qx "$slug"; then continue; fi
      # Convert ISO ts to epoch.
      [ -z "$ts" ] && continue
      epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
            || date -d "$ts" +%s 2>/dev/null \
            || echo 0)
      [ "$epoch" -eq 0 ] && continue
      age=$((now - epoch))
      if [ "$age" -gt "$STALE_CLAIM_SEC" ]; then
        by=$(echo "$line" | jq -r '.by // "?"')
        emit_alert stale_claim \
          "$(jq -nc --arg s "$slug" --arg b "$by" --arg a "$age" \
             '{slug:$s, by:$b, age_sec:($a|tonumber)}')"
      fi
    done < "$claims_file"
  fi

  # Parked-stale: scan KV state.agent.*.parked.
  for role in maya raj lin sam diego priya; do
    val=$(nats_admin kv get team-state "agent.$role.parked" --raw 2>/dev/null) || continue
    [ -z "$val" ] && continue
    echo "$val" | jq -c '.[]?' 2>/dev/null | while read -r entry; do
      ts=$(echo "$entry" | jq -r '.since // empty')
      slug=$(echo "$entry" | jq -r '.slug // empty')
      [ -z "$ts" ] || [ -z "$slug" ] && continue
      epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
            || date -d "$ts" +%s 2>/dev/null \
            || echo 0)
      [ "$epoch" -eq 0 ] && continue
      age=$((now - epoch))
      if [ "$age" -gt "$PARKED_STALE_SEC" ]; then
        emit_alert parked_stale \
          "$(jq -nc --arg r "$role" --arg s "$slug" --arg a "$age" \
             '{role:$r, slug:$s, age_sec:($a|tonumber)}')"
      fi
    done
  done

  # no_human relay (already published by agents; this just confirms reception).
  recent_msgs 'state.alert.no_human' --count 10 >/dev/null 2>&1 || true
}

case "${1:-tick}" in
  tick) tick ;;
  serve)
    while true; do tick; sleep "$WATCHER_INTERVAL"; done
    ;;
  *) echo "usage: $0 <tick|serve>" >&2; exit 2 ;;
esac
