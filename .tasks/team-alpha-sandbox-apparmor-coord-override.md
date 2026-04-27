---
column: InReview
created: 2026-04-27
order: 227
priority: low
parent: team-alpha-sandbox-personal-apparmor-overrides
depends_on: team-alpha-sandbox-personal-apparmor-overrides
---

> **Status (2026-04-27):** Stub-drop logic for the coord local
> override is part of Card 224's `install-in-vm.sh` (the
> kind=coord branch in the override-sync loop). Pending:
> `examples/personal-apparmor-coord` sample + the `team-alpha
> apparmor sync` mirror behavior (Card 228).

# Card 227 — Sandbox: personal coord override (mirror of worker policy)

Port from `~/Repos/ai-fleet-harness/.tasks/sandbox-apparmor-coord-override.md`.

Workers have `~/.team-alpha/apparmor/worker`; coord has nothing. If
coord runs on the same VM, it inherits the shared coord profile
with full `/Users/** r,` access — same exposure as worker
pre-override.

## Deliverables

- `install-in-vm.sh` already drops a stub at
  `/etc/apparmor.d/local/team-alpha-coord` (Card 226). Verify the
  kind=coord branch.
- `examples/personal-apparmor-coord` — sample mirroring worker.
- Default behavior in `team-alpha apparmor sync` (Card 228): write
  both files identically unless `[coord]` section in policy.toml
  overrides.
- `docs/sandbox.md`: short note that coord shares worker policy by
  default.

## Acceptance

- No `~/.team-alpha/apparmor/coord` → stub drop, `if exists`
  resolves cleanly.
- Mirror worker policy → `aa-exec -p team-alpha-coord -- ls
  /Users/me/Repos/<denied-repo>/` → Permission denied.
- `team-alpha apparmor sync` writes both files when no `[coord]`
  section in policy.toml.
