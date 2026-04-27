---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 239
priority: high
parent: team-alpha-meta-aon-cli
---

> **Status (2026-04-27, slice 5):** shipped subcommands `up`,
> `down`, `logs`, `status`. Resolves compose file (team repo
> first, engine fallback). `--project-name = basename($AON_TEAM_DIR)`
> for separate volumes per team. Up waits on `:8222/healthz`
> (10s timeout). Port-collision detection via `lsof :4222`
> with helpful error. Idempotent — own container running →
> early-return + healthz print. Smoke green; collision case
> verified by bringing two teams up sequentially.

# Card 239 — `aon nats up` / `aon nats down`

Currently the operator runs `docker compose -f $(realpath
~/Repos/ai-over-nats)/docker-compose.yml up -d nats` from the
team repo. Multi-line, error-prone, requires the right cwd, no
collision detection.

## Goal

```bash
aon nats up      # start NATS bound to ./nats/auth.conf
aon nats down    # stop + remove
aon nats logs    # tail
aon nats status  # ps + healthz
```

## Behavior

- Resolves compose file: prefers per-team `docker-compose.yml`
  if present (Card 240 makes it standard); else falls back to
  the engine's `$AON_ENGINE_DIR/docker-compose.yml` with
  `--project-directory $AON_TEAM_DIR`.
- Sets `--project-name $(basename $AON_TEAM_DIR)` so multiple
  teams on one host get separate volumes.
- Detects port 4222 collision before starting (`lsof -i :4222`)
  and refuses with a clear message + `aon nats down` hint.
- `up` waits for `:8222/healthz` to return `{"status":"ok"}`
  before exiting (with timeout).

## Acceptance

- Empty new team repo + `aon init` + `aon nats up` → NATS
  reachable on 127.0.0.1:4222 within 10s.
- Port-conflict scenario: existing NATS on 4222 → `aon nats up`
  exits non-zero with `port 4222 in use`.
- Two teams on same host with different basenames + `aon nats up`
  in each = error (port collision is real). Recommend
  documenting how to override the port via aon.toml.

## Why

Removes one of the top friction items from the POC trial.
