---
column: Done
created: 2026-04-25
order: 201
defect: true
affects: 08-card-claim-race, 09-double-work-detection, 10-stale-claim-gc
---

# Defect — coordinator-watcher cannot replay history from JetStream subjects

## Symptom

Sim scripts 08, 09, 10 fail: watcher does not emit `state.alert.duplicate_claim` /
`duplicate_result` / `stale_claim` after sim publishes the triggering events.

## Diagnosis

`scripts/coordinator-watcher.sh` calls `recent_msgs <subject>` which uses:

```
nats sub <subject> --since 10m --count 500 --raw --wait 2s
```

Behavior observed (manual repro):

```
$ nats sub 'board.tasks.*.claimed' --since 10m --count 50 --wait 2s --raw
20:43:29 Subscribing to JetStream Stream (direct) ...messages since 10m0s
[no output, exits after wait]
```

`nats sub --since` against a JS-covered subject auto-binds to the source stream
(TASKS, workqueue retention). Workqueue deletes messages on first ack; in tests,
there's no consumer to ack, but nats v0.3.2 still doesn't replay them through
`--since` direct binding. Result: watcher sees 0 historical events and never
detects duplicates.

## Hypothesis

Need to bind via the AUDIT stream (limits retention, full mirror) instead of
the source workqueue streams. AUDIT keeps everything 365d, so subject filtering
on AUDIT replays correctly.

## Fix candidates

1. **Pull-consumer-on-AUDIT** (cleanest): replace `recent_msgs` with:

   ```bash
   recent_msgs() {
     local subject="$1"
     # ephemeral consumer on AUDIT, filter by subject, deliver-all, batch read
     local cname="watcher-tick-$$-$RANDOM"
     nats_admin consumer add AUDIT "$cname" \
       --filter "$subject" --pull --deliver=all --ack=none \
       --replay=instant --no-headers-only --no-deny-delete \
       --defaults >/dev/null 2>&1
     nats_admin consumer next AUDIT "$cname" --count 500 --raw --wait 2s 2>/dev/null
     nats_admin consumer rm AUDIT "$cname" -f >/dev/null 2>&1
   }
   ```

2. **Direct stream view**: `nats stream view AUDIT --raw --subject "$subject"` —
   interactive, requires terminal; not viable.

3. **Live-only watcher**: drop tick mode, run watcher as `serve` daemon
   subscribing live to all subjects; maintain in-memory state. Sims spawn the
   daemon before publishing. Loses replay on watcher restart.

Recommend candidate 1.

## Acceptance

- [ ] 08, 09, 10 all PASS via `bash scripts/smoke/run-all.sh`.
- [ ] Watcher tick completes in under 5s for a 500-msg AUDIT.
- [ ] Ephemeral consumers cleaned up after each tick (no
      `nats consumer ls AUDIT` accumulation).
- [ ] No regression in live-sub behavior (still works for `serve` mode).

## Workaround until fixed

These three smoke checks won't fire detection. The sim *publishes* the
violation events; AUDIT *captures* them. Maya can manually inspect via
`nats stream view AUDIT --subject 'board.tasks.*.claimed'` until the watcher
is fixed.
