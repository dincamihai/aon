---
column: Backlog
created: 2026-04-28
order: 1095
priority: high
parent: team-alpha-team-portability
depends_on: team-alpha-meta-auth-out-of-repo
---

# Card — Directory bind-mount for /etc/nats/runtime

## Context

The auth-out-of-repo card moved `auth.conf` to `~/.aon/teams/<team>/auth.conf` and bind-mounts that single file into `/etc/nats/auth.conf`. This works on Linux + native Docker, but on macOS hosts (Docker Desktop VirtioFS, colima 9p/virtiofs) **single-file bind-mount in-place edits don't reliably propagate into the container**. SIGHUP succeeds, nats-server logs `Reloaded: authorization users`, but it reads stale content — the freshly-onboarded role's password mismatches and joiner handshake fails with `Authorization Violation` despite correct credentials.

Hit live during prototype rollout: `aon onboard vahid …` → SIGHUP success → probe `Authorization Violation` → `docker cp <container>:/etc/nats/auth.conf` showed a different mihai password than the host file. We patched around it twice — first by preserving the host inode (`cat tmp > $OUT` instead of rename) so Linux SIGHUP reload sees fresh content, then by adding a post-SIGHUP probe in `cmd_onboard` that force-recreates the container on mismatch (drops connections, but reliably picks up new auth.conf via the new mount).

Both are workarounds. The clean fix is to **bind-mount the directory, not the file**. Directory bind-mounts on macOS work consistently because the FS proxy watches inotify on the directory inode; new file content inside that dir is fetched on read.

## What changes

### New layout

```
~/.aon/teams/<team>/
  nats/                          # NEW — bind-mounted into container ro
    auth.conf
    auth.conf.example
  .passwords                     # stays at parent level — NOT in mount
  creds/                         # joiner per-role, unchanged
  repo -> $TEAM_AON_DIR          # symlink, unchanged
```

`.passwords` deliberately stays at the parent dir, so the password map never enters the container's view.

### Container mount

- **Before:** `~/.aon/teams/<team>/auth.conf:/etc/nats/auth.conf:ro` (single file)
- **After:** `~/.aon/teams/<team>/nats/:/etc/nats/runtime/:ro` (directory)

### NATS server config (`templates/nats-server.conf`)

- **Before:** `include "auth.conf"` (resolves relative to `/etc/nats/nats-server.conf` → `/etc/nats/auth.conf`)
- **After:** `include "/etc/nats/runtime/auth.conf"` (absolute path inside the mounted dir)

### docker-compose template (`templates/docker-compose.yml.tmpl`)

- **Before:** `- @AUTH_CONF_PATH@:/etc/nats/auth.conf:ro`
- **After:** `- @NATS_DIR_PATH@:/etc/nats/runtime/:ro`

`aon init` substitutes `@NATS_DIR_PATH@=~/.aon/teams/<team>/nats`.

### Helpers (`bin/_aon-lib.sh`)

```bash
_aon_team_nats_dir()         # ~/.aon/teams/<team>/nats
_aon_team_auth_conf()        # ~/.aon/teams/<team>/nats/auth.conf       (UPDATED)
_aon_team_auth_conf_example()# ~/.aon/teams/<team>/nats/auth.conf.example (UPDATED)
_aon_team_passwords()        # ~/.aon/teams/<team>/.passwords           (UNCHANGED — not in mount)
```

### `cmd_auth_*`

Drop the inode-preserving hacks (`cat $TMP > $OUT`). With directory bind-mount, plain `install -m 0644 $TMP $OUT` (renames into place) is safe — the container resolves the path through the dir and picks up the new inode on next read.

### `cmd_onboard` step 5

Drop the post-SIGHUP probe + force-recreate fallback. SIGHUP reliably reloads from the new file under directory bind-mount.

### Migration helper

```bash
aon nats migrate-mount   # idempotent
                         # mkdir -p ~/.aon/teams/<team>/nats
                         # mv ~/.aon/teams/<team>/auth.conf nats/
                         # mv ~/.aon/teams/<team>/auth.conf.example nats/
                         # warns operator: regenerate docker-compose.yml + bounce nats
```

Or fold migration into existing `aon auth migrate` so a single command handles both layout transitions for operators who skipped the prior one.

### Files NOT changed

- `~/.aon/teams/<team>/.passwords` — stays at parent.
- `~/.aon/teams/<team>/creds/<role>.{password,env}` — joiner side, unchanged.
- Joiner-side flow (no NATS container).
- ACL templates, agent prompts.

## Verification

1. `aon init` in fresh dir → renders `docker-compose.yml` with `@NATS_DIR_PATH@` substituted to `~/.aon/teams/<team>/nats`.
2. `aon auth render && aon auth set-passwords` → writes `~/.aon/teams/<team>/nats/auth.conf` (and `.example`).
3. `aon nats up` → mounts the dir; container starts healthy.
4. `aon onboard NEWROLE BITS` → SIGHUP → handshake passes immediately on macOS host without container recreation.
5. `docker exec <container> cat /etc/nats/runtime/auth.conf | grep NEWROLE` → role present, matches host file byte-for-byte.
6. Repeat 4 + 5 ten times; never hit a stale-content failure (the workaround branch in `cmd_onboard` should never fire).
7. Pre-existing teams: `aon nats migrate-mount` moves auth.conf into the new subdir; `aon nats down && aon nats up` picks up the new mount.
8. Verify `.passwords` is NOT visible inside container (`docker exec ... ls /etc/nats/runtime/` shows only auth.conf + auth.conf.example).

## Out of scope (separate cards)

- NSC JWT auth — different auth backend entirely.
- Multi-host operator failover (auth.conf replication).
- Watch-mode auto-reload (using `inotifywait` instead of explicit SIGHUP).
- Rotating per-role passwords without a full auth.conf regen.
