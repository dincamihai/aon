---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 230
priority: low
parent: team-alpha-sandbox-personal-apparmor-overrides
depends_on: team-alpha-sandbox-personal-apparmor-overrides
---

> **Status (2026-04-27, smoke green):** Posture flipped to
> allowlist:
>
> - Removed `/Users/** r,` from `team-alpha-coord` and
>   `team-alpha-worker` profiles. Kept `/mnt/** r,` for legacy
>   single-repo path.
> - `abstractions/team-alpha-base` documents the new posture in a
>   leading comment block (no rule emitted there).
> - `team-alpha-apparmor sync` now emits ALLOW rules for repos in
>   `allow_orgs` AND keeps explicit DENY rules for
>   `deny_orgs`/`deny_no_remote` as a tripwire.
> - `examples/personal-apparmor-{worker,coord}` show
>   allowlist-style samples.
> - `docs/sandbox.md` "Allowlist posture" section.
>
> Smoke: pushed updated profiles to VM, re-synced, verified via
> aa-exec as ta-worker-raj:
>
> - read `/Users/mid/Repos/ccc/` (exasol, allow_orgs) → allowed.
> - read `/Users/mid/Repos/ai-over-nats/` (no remote) → denied.
> - read `/Users/mid/.ssh/` → denied (no rule under /Users at all).
>
> Fail-closed achieved: a fresh `git clone` to `~/Repos/<x>` is
> invisible until policy + sync grant it.

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
