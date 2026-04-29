---
column: Backlog
---

# aon auth render: config sync with docker-compose mount
## Problem

`aon auth render` generates updated `nats-server.conf` in `~/.aon/teams/<team>/nats/` but docker-compose mounts from repo's `./nats/nats-server.conf`. When config diverges, NATS container uses stale operator JWT + system account, causing auth failures.

## Root Cause

- Auth render updates: `~/.aon/teams/<team>/nats/nats-server.conf`
- Docker-compose mounts: `./nats/nats-server.conf` (from repo)
- No mechanism syncs these after auth changes

## Observed Symptom

After `aon auth render`, bootstrap fails with "Account fetch failed: fetching jwt timed out" → "authentication error" because NATS server has mismatched operator JWT vs sysadmin creds.

## Solution Options

1. **Sync after render**: `aon auth render` copies config to repo after generation
2. **Mount from ~/.aon**: docker-compose mounts from ~/.aon instead of repo (but breaks git workflow)
3. **Verify on startup**: `aon nats up` checks config hash/mtime and warns if stale

Recommend option 1 — keep repo as source of truth, auto-sync.
