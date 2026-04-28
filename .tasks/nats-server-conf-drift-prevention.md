---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 47
priority: normal
parent: nsc-jwt-migration
---

**Shipped** in 535eb2a — `nats/nats-server.conf` replaced by a
symlink to `../templates/nats-server.conf` (option 1 from this
card). Single source of truth; drift impossible.



# Prevent drift between `nats/nats-server.conf` and `templates/nats-server.conf`

S2 cutover landed two near-identical config files with the same
JWT placeholders (@OP_JWT@, @SYS_ID@, @SYS_JWT@):

- `nats/nats-server.conf` — engine-local dev convenience.
- `templates/nats-server.conf` — per-team rendered file (the
  canonical source).

Risk: someone edits one without the other. Drift goes silent until
a dev-vs-prod-shape divergence breaks a smoke or, worse, a live
substrate.

## Options

1. **Symlink**: `nats/nats-server.conf -> ../templates/nats-server.conf`.
   Simplest. Loses the engine-specific header comment.
2. **Generate from template at engine setup**: drop the engine-local
   file entirely; `aon nats up` (engine-dev mode) renders the
   template into a tempdir + bind-mounts. No on-disk duplicate.
3. **Lint check in CI**: add a smoke step that diffs the two and
   fails on any divergence outside the header comment block.

Recommendation: **option 2**. Eliminates the file rather than
policing it. Engine-dev path goes through the same render pipeline
as real teams, so what works in dev works in prod.

## Acceptance

- Only `templates/nats-server.conf` exists in repo (option 2)
  OR `nats/nats-server.conf` is a symlink to it (option 1)
  OR a CI lint blocks PRs that diverge them (option 3).
- Engine-dev `aon nats up` still works.
- nsc-smoke phases A/B/C still pass.

## Out of scope

- Renaming or restructuring the resolver dir layout.
- Eliminating the templates/ directory altogether.
