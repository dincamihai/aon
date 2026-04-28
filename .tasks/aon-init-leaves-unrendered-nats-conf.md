---
column: Backlog
created: 2026-04-28
order: 50
priority: high
parent: nsc-jwt-migration
---

# `aon init` writes unrendered nats-server.conf to team repo

`aon init` for a fresh team-aon repo copies
`templates/nats-server.conf` (which holds `@OP_JWT@` / `@SYS_ID@` /
`@SYS_JWT@` / `@TEAM_NAME@` placeholders) into
`<team-repo>/nats/nats-server.conf`. `aon auth render` substitutes
those placeholders into `~/.aon/teams/<team>/nats/nats-server.conf`
(the runtime dir) but does **not** update the team-repo copy.

Container restart-loops on `error parsing operator JWT: open
@OP_JWT@: no such file or directory` because the docker-compose
mounts `./nats/nats-server.conf` (template) and command points at it.

## Repro (clean state)

```
mkdir ~/Repos/foo && cd ~/Repos/foo
aon init
aon add-role admin manager fullstack
aon auth render
aon creds --all
aon nats up
docker logs foo-nats-1   # → @OP_JWT@: no such file or directory
```

Workaround used today:

```
cp ~/.aon/teams/foo/nats/nats-server.conf ~/Repos/foo/nats/nats-server.conf
aon nats down && aon nats up
```

## Fix (pick one)

1. **Make `aon auth render` also render into `<team-repo>/nats/`**.
   Two writes per render. Simplest change. Keeps current docker-
   compose mount shape.
2. **Drop the team-repo `nats/nats-server.conf` copy entirely.**
   Change docker-compose to `command: -c /etc/nats/runtime/nats-server.conf`
   and remove the single-file mount. Runtime dir already mounted; it
   has the rendered file. Cleaner separation: team-repo holds
   compose template only, `~/.aon` holds operational state.
3. **Symlink team-repo `nats/nats-server.conf` → runtime path**.
   `aon init` creates the symlink instead of copying. Same end
   result as #2 with less compose churn. Symlinks are awkward
   inside docker bind-mounts on macOS though (resolves on host
   side, ok).

Recommend **#2**: cleanest separation, no duplication risk. Compose
already has the runtime dir mount.

## Acceptance

- Fresh `aon init <new-team>` + add-role + auth render + creds + nats
  up → container reaches healthy without manual file copy.
- Existing teams (saas, workers) still work (compose update is
  backward-compatible: runtime-mounted file always exists post
  `aon auth render`).
- nsc-smoke run-smoke.sh Phase C continues green (smoke uses runtime
  mount only — already aligned with #2).
- `aon doctor` adds a check: warn if `<team-repo>/nats/nats-server.conf`
  contains placeholders (catches half-migrated teams).

## Out of scope

- Migrating saas + workers to runtime-only mount (one-time docker-
  compose edit + `aon nats down/up`). Document in the cutover
  appendix.
