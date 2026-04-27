---
column: Backlog
created: 2026-04-27
order: 230
priority: low
parent: team-alpha-sandbox-personal-apparmor-overrides
depends_on: team-alpha-sandbox-personal-apparmor-overrides
---

# Card 230 — Sandbox: flip /Users/Repos from blocklist to allowlist

Port from `~/Repos/ai-fleet-harness/.tasks/sandbox-apparmor-allowlist-refactor.md`.

Default fleet-harness posture: shared profile broadly allows
`/Users/** r,`; personal denies carve back. Net = **fail-open** on
any repo cloned after the last sync.

Better posture: **fail-closed**. Shared profile allows nothing
under `/Users/$USER/Repos/`; the personal local override allows
specific paths.

## Goal

Fresh `git clone ~/Repos/whatever` is invisible to workers until
operator explicitly allows it.

## Deliverables

- `scripts/sandbox/apparmor/team-alpha-worker`: drop or scope
  `/Users/** r,` so it does not cover `/Users/$USER/Repos/**`.
  Same for coord profile.
- `scripts/sandbox/apparmor/abstractions/team-alpha-base`: doc
  comment explaining the new posture.
- `~/.team-alpha/apparmor/worker.example`: now allow-style:
  ```
  /Users/me/Repos/ccc/    r,
  /Users/me/Repos/ccc/**  r,
  ```
- `team-alpha apparmor sync` (Card 228): emits **allow** rules
  instead of deny rules when policy `default = "deny"`.
- `docs/sandbox.md`: rewrite "Personal AppArmor overrides" to
  describe the new model.

## Acceptance

- Without any `~/.team-alpha/apparmor/worker`, worker cannot read
  any repo under `/Users/$USER/Repos/`. `aa-exec -p team-alpha-worker
  -- ls /Users/me/Repos/ccc/` → Permission denied.
- With explicit allow lines for ccc, worker reads ccc but nothing
  else under Repos.
- Worker still reads `~/.team-alpha/apparmor` (own override file
  path), `~/.gitconfig`.

## Risks

- Coord profile also needs the change.
- Re-audit any harness self-reference that previously worked via
  the broad `/Users/** r,` rule.
