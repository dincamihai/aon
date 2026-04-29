---
column: Backlog
---

# aon: document auth render → nats-server.conf sync requirement
## Problem

Users following the onboarding workflow (`aon init` → `aon auth render` → `aon bootstrap`) hit a silent config desync: rendered `nats-server.conf` in `~/.aon` diverges from repo version mounted by docker-compose.

## Current Workflow Gap

- `aon auth render` outputs: "✓ rendered /home/mihai/.aon/teams/workers/nats/nats-server.conf"
- No indication that repo's `./nats/nats-server.conf` now differs
- Docker-compose uses stale repo version
- Only discoverable when bootstrap fails with cryptic JWT auth errors

## Fix

Add to `aon auth render` output:

```
⚠ Manual sync required:
  cp ~/.aon/teams/<team>/nats/nats-server.conf ./nats/nats-server.conf
  git add nats/nats-server.conf && git commit
```

Or better: make it automatic (see companion card).

## Docs Update

Update onboarding guide to clarify:
- Rendered artifacts live in `~/.aon`
- Repo-mounted artifacts must be in sync
- When to re-render/re-sync
