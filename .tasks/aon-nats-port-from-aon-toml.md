---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 51
priority: high
parent: nsc-jwt-migration
---

# `aon nats up` hardcoded :4222 — wrong for multi-team-on-host

**Shipped** in this commit. `_aon_nats_port_in_use`,
`_aon_nats_external_serving`, and `cmd_nats_up` error/info messages
all hardcoded port 4222. Multi-team setups (e.g. mihai running both
team-saas on :4222 and `workers` on :4322) broke: workers' `aon
nats up` saw saas's NATS on :4222 and bailed with "external NATS
already serving — skipping docker start", never starting workers'
container.

## Fix

Added `_aon_nats_port` helper that extracts host port from
`$AON_NATS_URL` (loaded from team's `aon.toml` `nats.url`). Falls
back to 4222 if unset.

`_aon_nats_port_in_use` now lsof's the team's actual port.
`_aon_nats_external_serving` now socket-connects to the team's
port. `cmd_nats_up` info/error lines now reference the team's
port, not the hardcoded 4222.

## Verified

- saas team on :4222 + workers team on :4322 coexist on same host.
- workers' `aon nats up` no longer false-positives on saas's
  external NATS.
- saas existing flow unchanged (port = 4222 default).

## Out of scope

- Auto-allocating a free port at `aon init` time (separate UX card
  if multi-team becomes common).
- Updating healthcheck URL line (`http://127.0.0.1:8222/healthz`)
  — that's the in-container monitor port, fine. Could be
  `port+4000` to match host monitor port mapping; left as-is to
  not perturb saas.
