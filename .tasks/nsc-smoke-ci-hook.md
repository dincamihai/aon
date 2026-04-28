---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 45
priority: normal
parent: nsc-jwt-migration
---

**Shipped** in d0553e3 — `.github/workflows/nsc-smoke.yml`. Ubuntu
runner, 10min timeout, concurrency cancel-in-progress, nsc 2.12.2
pinned, pre-pulls nats:latest, runs full smoke.



# CI hook: run scripts/nsc-smoke/run-smoke.sh on every push to main

`scripts/nsc-smoke/run-smoke.sh` is now 464 lines, two-phase
(memory + dir resolver), 37 ACL parity cases. Without CI, refactors
silently rot it. Both phases need Docker + nsc, which means CI
runner needs Docker-in-Docker or a real Docker daemon.

## Goal

Every push to `main` runs the smoke. Red = ACL parity broke; revert
or fix before further work on JWT pipeline.

## Scope

- Add `.github/workflows/nsc-smoke.yml` (or matching CI vendor):
  - macOS / linux runner with Docker available.
  - Install `nsc` (brew on macos, binary download on linux).
  - Install `coreutils` (gtimeout) where needed.
  - `bash scripts/nsc-smoke/run-smoke.sh` — must exit 0.
- Cache `nsc` install if practical.
- Time budget: smoke must finish < 5 min (currently runs in ~30s
  per phase, comfortably under).

## Acceptance

- PR opened that intentionally breaks ACL claim → CI red, blocks
  merge.
- PR opened that adds a new role to fixture roster → CI green if
  translation pattern holds.
- Smoke runs unattended on every push to `main`; result visible
  in commit checks.

## Out of scope

- Running smoke on every `nsc-jwt-migration` slice independently
  (it always runs the full thing).
- Productionizing the smoke as the team-saas live test (engine vs
  consumer concern — engine validates with fixtures, downstream
  teams write their own integration tests).
- Pre-commit hook (workers run smoke locally as needed; CI is the
  back-stop).

## Notes

- macOS GitHub runner is paid; linux runner is free. Linux preferred
  unless Docker file-share gotcha (smoke uses `/Users` as workdir to
  side-step macOS Docker Desktop file-share limits) — on linux that
  constraint disappears, can put workdir anywhere.
