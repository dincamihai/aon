---
column: Done
created: 2026-04-25
order: 203
defect: true
affects: scenario-01-normal-task, sim/_lib.sh::audit_events_for_slug
---

# Defect — audit aggregate query (`board.>`) misses events under load

## Symptom

`scripts/sim/scenario-01-normal-task.sh`:

```
✓ maya posted task t-...
✓ priya claimed + shipped t-...
✗ AUDIT has 0 events for t-... (expected 4)
✓ single claimer = priya
✓ single shipper = priya
```

The single-subject queries (`board.tasks.*.claimed`,
`board.results.>`) succeed. The aggregate (`board.>`) returns 0 matching
events.

## Diagnosis

`audit_events_for_slug 'board.>' $slug` creates a pull consumer with
`--filter board.>` and reads `--count 200` messages. If AUDIT has older
unrelated `board.>` traffic from previous runs (e.g. empty `{}` payloads
from earlier scenarios or smoke tests), the first 200 returned messages
exclude our recently-published quartet — they're past the count window.

`jq 'select(.slug == $s)'` then returns empty.

## Hypothesis

Two fixes possible:

1. **Time-bounded read**: add `--start-time` to consumer config so it only
   sees messages from N seconds before the scenario started. Eliminates
   stale-history noise.

2. **Larger count or batched reads**: scan 2000+ msgs, accept higher
   roundtrip cost. Brittle — fails again at next AUDIT growth threshold.

Recommend (1).

## Fix candidate

```bash
audit_events_for_slug() {
  local subject="$1" slug="$2"
  local since="${3:-30s}"        # default lookback 30s
  local cname="sim-$$-$(date +%s%N)-$RANDOM"
  as_role sysadmin consumer add AUDIT "$cname" \
    --filter "$subject" --pull --deliver=by-start-time \
    --opt-start-time "$(date -u -v-30S +%FT%TZ)" \
    --ack=none --replay=instant --ephemeral --defaults \
    >/dev/null 2>&1 || { echo ""; return; }
  as_role sysadmin consumer next AUDIT "$cname" --count 200 --raw --wait 1s 2>/dev/null \
    | jq -c --arg s "$slug" 'select(.slug == $s)' 2>/dev/null
  as_role sysadmin consumer rm AUDIT "$cname" -f >/dev/null 2>&1 || true
}
```

Verify nats v0.3.2 supports `--deliver=by-start-time` and `--opt-start-time`
flags. If not, use `--deliver=new` and capture only future events (less
useful for replay-style assertions).

## Acceptance

- [ ] scenario-01 passes 5/5 even after 100 prior smoke runs accumulate
      AUDIT noise.
- [ ] All other scenarios still pass (regression check).
- [ ] `audit_events_for_slug` documented with the lookback parameter.

## Workaround until fixed

Use single-subject queries (which already work) or run against a freshly
bootstrapped AUDIT.
