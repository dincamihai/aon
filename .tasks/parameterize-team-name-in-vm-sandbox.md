---
column: Backlog
---

# Parameterize team name in VM sandbox — remove `ta-worker-` / `team-alpha` hardcoding

## Problem

All sandbox scripts hardcode `team-alpha` and the `ta-worker-` prefix:
- Linux group: `team-alpha`
- Worker UIDs: `ta-worker-<role>`
- Paths: `/etc/team-alpha/`, `/var/lib/team-alpha/`, `/work/workers/`
- AppArmor profile names: `team-alpha-worker`, `team-alpha-coord`
- AppArmor abstractions: `team-alpha-base`
- ACL rules, env files, creds paths

This makes the VM sandbox single-tenant. A second team can't run in the same VM without collision.

## Goal

Derive all team-scoped identifiers from `[team] name` in `aon.toml`:

```
team_name   = "platform-team"          # from aon.toml
worker_user = "platform-team-worker-sun"
group       = "platform-team"
paths       = /etc/platform-team/ /var/lib/platform-team/ /work/platform-team/workers/
apparmor    = platform-team-worker, platform-team-coord, platform-team-base
```

## Files to update

- `scripts/sandbox/install-in-vm.sh` — accept `TA_TEAM` env (default: `team-alpha`); replace all hardcoded strings
- `scripts/sandbox/add-worker.sh` — `USER_NAME="${TA_TEAM}-worker-$NAME"`
- `scripts/sandbox/start-agent-in-vm.sh` — derive group/paths from `TA_TEAM`
- `scripts/sandbox/aon-tmux.sh` — derive `ta-worker-` from team name
- `scripts/sandbox/apparmor/team-alpha-worker` → template; rendered per-team as `<team>-worker`
- `scripts/sandbox/apparmor/team-alpha-coord` → same
- `scripts/sandbox/apparmor/abstractions/team-alpha-base` → `<team>-base`
- `scripts/sandbox/colima-up.sh` — pass `TA_TEAM` through
- `bin/aon` `cmd_vm` — read team name from `aon.toml`, export as `TA_TEAM`

## Approach

1. `TA_TEAM` env var (set by `aon vm` from `aon.toml [team] name`) flows into all sandbox scripts
2. Scripts compute derived names: `WORKER_PREFIX="${TA_TEAM}-worker"`, group = `$TA_TEAM`
3. AppArmor profiles rendered from templates at install time with team name substituted
4. Default `TA_TEAM=team-alpha` preserves backward compat for existing deployments

## Acceptance

- `aon vm` with `[team] name = "platform-team"` in aon.toml creates `platform-team-worker-*` users, `/etc/platform-team/`, AppArmor `platform-team-worker` profile
- Existing `team-alpha` deployments work unchanged (`TA_TEAM` defaults to `team-alpha`)
- Two teams can coexist in the same VM without UID/path collision
