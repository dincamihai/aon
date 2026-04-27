---
column: InReview
created: 2026-04-27
order: 226
priority: medium
parent: team-alpha-sandbox-arm-colima-apparmor
depends_on: team-alpha-sandbox-arm-colima-apparmor
---

> **Status (2026-04-27):** Mechanism shipped together with Card
> 224. `#include if exists <local/team-alpha-{base,coord,worker}>`
> lines present in all three shared profiles. `colima-up.sh`
> mounts `$HOME/.team-alpha/apparmor` ro by default;
> `install-in-vm.sh` syncs to `/etc/apparmor.d/local/team-alpha-*`
> with annotated stub fallback. `reload-apparmor.sh` ships.
> Pending: VM smoke test of the deny + allow examples.

# Card 226 — Sandbox: personal AppArmor override files (out-of-repo)

Port from `~/Repos/ai-fleet-harness/.tasks/sandbox-personal-apparmor-overrides.md`.

Shared profiles ship in-repo. Each operator wants to **tighten**
or **extend** policy with local rules — e.g. deny worker access to
a private repo, allow a non-standard tool — without committing
those rules.

## How it works

1. AppArmor `#include if exists <local/...>` in each shared profile:
   - `abstractions/team-alpha-base` → `<local/team-alpha-base>`
   - `team-alpha-coord` → `<local/team-alpha-coord>`
   - `team-alpha-worker` → `<local/team-alpha-worker>`
2. Operator drops files at `$HOME/.team-alpha/apparmor/{base,coord,worker}`.
3. `colima-up.sh` defaults `FLEET_LOCAL_APPARMOR=$HOME/.team-alpha/apparmor`
   and adds `--mount <path>:r` on first VM start.
4. `install-in-vm.sh` copies into `/etc/apparmor.d/local/team-alpha-<kind>`,
   runs `apparmor_parser -r`. Missing host file → annotated stub.
5. `reload-apparmor.sh` re-parses without re-running provisioner.

AppArmor unions allow + deny across all included files; **deny
always wins**.

## Gotcha (captured from fleet-harness smoke test)

`**` does NOT match the directory entry itself. To deny a whole
subtree both forms needed:

```
deny /Users/me/Repos/secrets/    rwklx,
deny /Users/me/Repos/secrets/**  rwklx,
```

## Deliverables

- `#include if exists` lines wired into all three shared profiles.
- `install-in-vm.sh` mount + sync logic.
- `reload-apparmor.sh`.
- `examples/personal-apparmor-{worker,coord}` samples.
- `docs/sandbox.md` "Personal AppArmor overrides" section.

## Acceptance

- Empty `~/.team-alpha/apparmor/` → VM still boots; stubs at
  `/etc/apparmor.d/local/team-alpha-*` resolve `if exists`.
- Drop `deny /Users/me/Repos/secret/{,**} rwklx` in worker file →
  `aa-exec -p team-alpha-worker -- ls /Users/me/Repos/secret/` →
  Permission denied. Other repos still readable.
- Edit + `reload-apparmor.sh` re-applies in <1s.
