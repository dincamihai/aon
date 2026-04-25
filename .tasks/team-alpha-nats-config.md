---
column: Done
created: 2026-04-25
order: 10
---

# NATS server config — team-alpha account, 6 users, permissions per MODEL.md

Write `nats/nats-server.conf` + gitignored `nats/auth.conf` modeling the team
described in [MODEL.md](../MODEL.md).

## Scope

- Single account `team-alpha`.
- Six users: `maya`, `raj`, `lin`, `sam`, `diego`, `priya`.
- Auth: user+password (mirror membrain POC at `~/Repos/membrain/nats/nats-server.conf`).
  NSC/JWT deferred — see `nsc-jwt-migration.md`.
- Permissions per role exactly as sketched in [MODEL.md](../MODEL.md) §"Permissions
  — modeling capability and growth".
- JetStream enabled (file store, sized for POC: 256MB mem, 4GB file).
- Websocket on 8080 (no TLS — terminate at edge), HTTP monitor on 8222.
- Cluster-ready: include `cluster {}` block stubbed for multi-host (routes empty by
  default; operator fills in per-deployment). Server name from env or hostname.

## Files to create

- `nats/nats-server.conf` — committed. Sources `auth.conf` via `include`.
- `nats/auth.conf.example` — committed. Template with placeholders.
- `nats/auth.conf` — gitignored. Real passwords (generate with `openssl rand -hex 24`).
- `.gitignore` — add `nats/auth.conf`, `creds/`, `*.creds`, `*.nats-token`.

## Permission mapping (from MODEL.md)

Translate each role's `publish` / `subscribe` / `deny_publish` into NATS
`permissions { publish { allow = [...] } subscribe { allow = [...] } }`. Subjects
use literal `*` and `>` wildcards — bash brace expansions in MODEL.md (e.g.
`board.tasks.python.{claimed,blocked,done}`) must be expanded into explicit
subject lists in the conf, since NATS does not parse braces.

Example for Lin (mid generalist, learning Go):

```
lin: {
  password: "$LIN_PASSWORD"
  permissions: {
    publish: {
      allow: [
        "agents.*.inbox",
        "board.tasks.python.claimed", "board.tasks.python.blocked", "board.tasks.python.done",
        "board.tasks.ui.claimed",     "board.tasks.ui.blocked",     "board.tasks.ui.done",
        "board.tasks.go.claimed",     "board.tasks.go.blocked",     "board.tasks.go.done",
        "board.results.python.>", "board.results.ui.>", "board.results.go.>",
        "board.learning.go.claimed",
        "agents.lin.events"
      ]
    }
    subscribe: {
      allow: [
        "agents.lin.inbox",
        "board.tasks.python.pending", "board.tasks.ui.pending", "board.tasks.go.pending",
        "board.learning.go.>",
        "broadcast.>"
      ]
    }
  }
}
```

Repeat for all six roles. `deny` block on Maya for `board.results.>`.

## Acceptance

- [ ] `nats-server -c nats/nats-server.conf -t` parses clean (use `-t` test flag).
- [ ] Six users present with permissions matching MODEL.md exactly (allow + deny).
- [ ] `auth.conf` gitignored; `auth.conf.example` committed.
- [ ] JetStream enabled, store dir `/data`.
- [ ] Websocket 8080, monitor 8222 — both bind 0.0.0.0 (multi-host).
- [ ] `cluster {}` block present, routes commented placeholder.
