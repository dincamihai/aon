---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 224
priority: medium
runtime: macOS + colima + Apple Silicon
---

> **Status (2026-04-27, smoke-tested):** Scripts + profiles +
> systemd units + docs/sandbox.md ported from `ai-fleet-harness`
> and renamed `ai-fleet-*` → `team-alpha-*`. sentrux gate clean
> (7777 → 7777). VM smoke green:
>
> - colima profile `team-alpha` (vz, aarch64, Ubuntu 24.04) boots
>   in ~1 min, install-in-vm provisions cleanly.
> - `aa-status`: `team-alpha-coord` + `team-alpha-worker` in
>   enforce mode, 41 enforced profiles total.
> - `add-worker.sh raj` creates `ta-worker-raj`, /work/workers/raj
>   0700, ACL grants ta-coord rx; templated unit enabled.
> - `team-alpha-nats` active, listening 127.0.0.1:4222.
> - Negative tests (run as `ta-worker-raj` + `aa-exec -p
>   team-alpha-worker`):
>   - read peer worktree (`/work/workers/lin/*`) → denied.
>   - write peer worktree → denied.
>   - read `/etc/shadow` → denied.
>   - read `/work/coord/*` → denied.
> - Positive: own worktree rw works; NATS token readable.
>
> Skipped (out of scope for base sandbox card):
>   - starting `claude` unit (needs API key + token interactivity).
>   - nft egress allowlist (intentional non-goal).

# Card 224 — Sandbox: ARM colima VM + AppArmor for team-alpha workers

Port the VM-isolation base layer from `ai-fleet-harness` (see
`~/Repos/ai-fleet-harness/.tasks/sandbox-arm-colima-apparmor.md` and
`docs/sandbox.md`). Adapt for team-alpha role taxonomy
(Maya/Raj/Lin/Sam/Diego/Priya) on top of the NATS substrate.

Single colima arm64 Ubuntu LTS VM hosts every role under separate
Unix UIDs with distinct AppArmor profiles + hardened systemd
units. Worker can't read host secrets, peer worktrees, or coord
state even if the model is compromised. This is the chosen
isolation path for team-alpha — VM + LSM + DAC, not containers.

## Three layers of isolation

1. **DAC** — per-role UID (`fleet-<role>`), `0750` on home + worktree.
2. **AppArmor** — `team-alpha-<role>` profiles with `owner` keyword,
   path globs scoped per UID, `deny` rules for `~/.ssh`, `~/.aws`,
   `/etc/shadow`, peer worker trees, `/work/coord/` from workers.
3. **systemd hardening** — `ProtectHome=tmpfs`, `InaccessiblePaths`,
   `BindReadOnlyPaths`, `CapabilityBoundingSet=`, `SystemCallFilter=
   @system-service`, `RestrictAddressFamilies=`.

## Deliverables

- `scripts/sandbox/colima-up.sh` — idempotent VM boot (vz on Apple
  Silicon, virtiofs mounts, NATS token gen at `/etc/team-alpha/nats-token`).
- `scripts/sandbox/install-in-vm.sh` — installs `apparmor-utils`,
  drops profiles, loads them, installs systemd units.
- `scripts/sandbox/apparmor/abstractions/team-alpha-base` — shared
  abstraction (deny ssh/aws/shadow, allow git/node/claude binary).
- `scripts/sandbox/apparmor/team-alpha-coord` — coord profile.
- `scripts/sandbox/apparmor/team-alpha-worker` — worker profile (own
  worktree rw only, no peer reads).
- `scripts/sandbox/systemd/team-alpha-{coord,worker@,nats}.service`.
- `scripts/sandbox/add-worker.sh` — creates `fleet-<role>`, mkdir
  `/work/workers/<role>/`, enables templated unit.
- `scripts/sandbox/reload-apparmor.sh` — fast in-VM re-parse loop.
- `docs/sandbox.md` — operator guide (port + adapt fleet-harness one).

## Acceptance

- `sudo aa-status | grep team-alpha` shows two profiles in `enforce`.
- `cat /proc/$(pgrep -u fleet-maya -f claude)/attr/current` →
  `team-alpha-worker (enforce)`.
- Negative tests pass: worker can't read peer worktrees,
  `/etc/shadow`, host `~/.ssh/id_rsa`.
- Positive: worker can claim a card, clone repo, push branch, hit
  NATS over loopback.
- `FLEET_AA_MODE=complain` available for first-pass `aa-logprof`
  rule harvesting; default `enforce`.

## Non-goals

- SELinux. Fedora. Multi-tenant. Network egress allowlist (defer to
  separate `nft` rules card if needed). Per-card path scoping
  (Landlock — see Card 232 / guardian work).

## Why AppArmor + VM (not containers)

AppArmor + dedicated UIDs + systemd hardening is a kernel-enforced
wall, reviewable in ~200 lines of profile, no relabel pain, ships
on Ubuntu by default. The VM is the trust boundary — deleting it
deletes all worker state and worktrees; project files on the host
are untouched (mount only).

## Reference

Full spec + rationale: `~/Repos/ai-fleet-harness/docs/sandbox.md`
and `~/Repos/ai-fleet-harness/.tasks/sandbox-arm-colima-apparmor.md`.
Profiles + scripts in `~/Repos/ai-fleet-harness/scripts/sandbox/`
are largely portable — rename `ai-fleet-*` → `team-alpha-*` and
adapt user names to role taxonomy.
