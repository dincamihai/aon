---
column: Done
priority: high
created: 2026-04-29
source: tim review (D2) on 4d5911b..62dc26d
---

# anon user `--deny-pub ">"` overrides `--allow-pub` — waiting-room joiner is silently denied

Commit `ad1658c` (`fix(auth): use anon.creds, fix anon ACLs, restrict inbox ACLs`).

`bin/_aon-lib.sh:442-443` — anon user has both `--allow-pub "team.${team}.waiting-room"` and `--deny-pub ">"`. In NATS JWT, deny takes precedence over allow. Result: every publish from anon is denied including the waiting-room subject. Joiner's `aon connect` calls `nats req` → silently denied → waiting-room flow is **dead**.

Same applies to `--deny-sub ">"` blocking the reply subscription.

The commit message claims "fix anon ACLs" but only added `_INBOX.>` to `allow-sub`. The deny-everything lines were NOT removed.

## Fix

```bash
anon)
  nsc add user --account "$team" "$name" \
    --allow-pub "team.${team}.waiting-room" \
    --allow-sub "team.${team}.waiting-room.*.reply,_INBOX.>" \
    --allow-pub-response >/dev/null
  ;;
```

(Allow-list-only is sufficient — anon already cannot reach anything outside the listed subjects.)

## Acceptance

1. `aon connect` from a fresh anon publishes to `team.<team>.waiting-room` without "Permissions Violation".
2. `scripts/smoke/01-auth-boundaries.sh` (or new test) covers anon publishing to allowed subject + denied subject (e.g. `agents.tim.inbox`).
3. Re-issued anon JWT propagated to running server (or document the requirement to restart).

## Why high

Together with D1, the entire waiting-room joiner+admin flow is unusable.
