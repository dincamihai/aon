---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 240
priority: high
parent: team-alpha-meta-aon-cli
---

> **Status (2026-04-27, slice 5):** `aon init` now copies
> `templates/nats-server.conf` → `nats/nats-server.conf` and
> renders `templates/docker-compose.yml.tmpl` →
> `docker-compose.yml` (with `@TEAM_NAME@` substituted). Both
> idempotent. Smoke green: empty dir + `aon init` produces a
> tree where `aon nats up` Just Works.

# Card 240 — `aon init` drops `docker-compose.yml` + `nats-server.conf`

Today `aon init` writes only `aon.toml` + dir tree. To bring up
NATS the operator must hand-copy `nats-server.conf` from the
engine and write a `docker-compose.yml`. Caught during POC
trial — both manual steps.

## Goal

After `aon init`, the per-team repo is self-contained for a NATS
bring-up:

```
<team>-aon/
  aon.toml
  agent-prompts/
  agents/
  hooks/
  .tasks/
  nats/
    nats-server.conf            ← copied from engine, committed
  docker-compose.yml            ← templated from engine, committed
```

## Deliverables

- `templates/docker-compose.yml.tmpl` — substitutes
  `@TEAM_NAME@` (server_name), `@AUTH_CONF@` (relative path),
  default ports, volume name.
- `templates/nats-server.conf` — verbatim copy of engine's
  current config (rendered identical for all teams; if a team
  needs to diverge, edit in-place).
- `cmd_init` writes both files when missing. Idempotent.
- README operator section drops the `docker compose -f $(realpath
  …)` complexity in favor of `aon nats up` (Card 239).

## Acceptance

- Empty dir + `aon init` produces a tree where `docker compose
  up -d` (from inside the team repo) brings up NATS bound to
  `./nats/auth.conf`.
- Re-running `aon init` does not clobber a hand-edited
  `nats-server.conf` — only writes if absent (or behind
  `--force`).
