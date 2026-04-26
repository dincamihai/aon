---
column: Backlog
created: 2026-04-26
order: 165
---

# Watcher leader election

Coordinator-watcher daemon runs on one ops box today. With multiple
ops boxes (or HA ops setup), 2+ watchers tick concurrently → every
alert fires twice.

NATS-native KV-lease leader election. ~30 LOC.

## Deliverables

### 1. Lease KV

`team-state.watcher.leader = {instance_id, lease_until}`. TTL 30s.

On each tick:
1. read leader KV
2. if `now > lease_until` OR `instance_id == self`: claim/extend
   lease via CAS (card 161 infra). Proceed with tick logic.
3. else: skip tick (peer is leader).

### 2. coordinator-watcher.sh changes

```bash
WATCHER_INSTANCE_ID="${WATCHER_INSTANCE_ID:-watcher-$(hostname)-$$}"
LEADER_TTL=30

# At top of tick():
ld=$(nats_admin kv get team-state watcher.leader --raw 2>/dev/null || echo "{}")
ld_until=$(echo "$ld" | jq -r '.lease_until // ""')
ld_inst=$(echo "$ld" | jq -r '.instance_id // ""')
now=$(date +%s)
if [ -n "$ld_until" ] && [ "$ld_inst" != "$WATCHER_INSTANCE_ID" ]; then
  ld_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ld_until" +%s 2>/dev/null || echo 0)
  [ "$now" -lt "$ld_epoch" ] && return 0   # peer is leader
fi
# claim/extend
new_until=$(date -u -v+30S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -d '+30 seconds' +%Y-%m-%dT%H:%M:%SZ)
nats_admin kv put team-state watcher.leader \
  "$(jq -nc --arg i "$WATCHER_INSTANCE_ID" --arg u "$new_until" \
     '{instance_id:$i, lease_until:$u}')" >/dev/null
# ... existing tick body ...
```

### 3. Smoke 31

- start 2 watcher daemons
- assert exactly one alerts per stale entry within 60s
- kill leader; assert peer takes over within 30s
- assert no overlap in alert emission

## Acceptance

- [ ] coordinator-watcher serve mode honors lease.
- [ ] Smoke 31 green.
- [ ] tick mode bypasses lease (operator manual ticks always run).

## Refs

- `team-alpha-a2a-ha-resilience.md` — umbrella.
- card 85 (preemption) — coordinator-watcher origin.
