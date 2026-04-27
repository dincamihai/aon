# Sandbox: ARM colima VM with AppArmor

Run team-alpha inside a Linux VM on macOS so a misbehaving worker (or compromised model) cannot read host secrets, exfiltrate data, or write outside its own worktree. Single VM hosts the **coord** plus **N workers** with separate Unix users and AppArmor profiles.

Why AppArmor and not SELinux: path-based, ships on Ubuntu by default, no relabel pain across virtiofs mounts, profiles are short and reviewable. SELinux gains nothing for single-tenant dev.

## Layout

```
host (macOS)                      VM (Ubuntu LTS, AppArmor enforce)
─────────────                     ──────────────────────────────────
~/Repos/ai-over-nats      ──r──►  /Users/.../ai-over-nats       (read-only)
~/Repos                   ──r──►  /Users/.../Repos              (read-only, multi-repo)

                                  /work/coord/                  ta-coord:team-alpha 0700
                                  /work/workers/<name>/         ta-worker-<name>:team-alpha 0700
                                  /etc/team-alpha/{env,nats.conf,nats-token}
                                  /var/lib/team-alpha/{coord,workers/<name>}/    home dirs
                                  /var/log/team-alpha/{coord.log,worker-<name>.log}
```

Three layers of isolation, each independent:

1. **DAC** — every role has its own UID; `0700` on home + worktree dirs.
2. **AppArmor** (`team-alpha-coord`, `team-alpha-worker`) — `owner` keyword + path globs scope reads/writes per UID. `deny` rules cover `/root`, `~/.ssh`, `~/.aws`, `/etc/shadow`, peer worker trees, `/work/coord` from workers.
3. **systemd hardening** — `ProtectHome=tmpfs`, `InaccessiblePaths=/work/coord` for workers, `BindReadOnlyPaths=/work/workers` for coord, `CapabilityBoundingSet=`, `SystemCallFilter=@system-service`, `RestrictAddressFamilies=`.

## Bring-up

From the host (macOS):

```bash
bash ~/Repos/ai-over-nats/scripts/sandbox/colima-up.sh
```

This:

- Picks `vz` on Apple Silicon macOS 13+, qemu otherwise; `aarch64` on arm64 hosts, `x86_64` on Intel.
- Mounts ai-over-nats read-only and `~/Repos` read-only into the VM via virtiofs.
- Runs `install-in-vm.sh` as root inside the VM: installs `apparmor-utils`, creates `ta-coord` user, drops profiles, loads them, installs systemd units, generates a per-VM NATS token at `/etc/team-alpha/nats-token`.
- Starts `team-alpha-nats` (loopback only, token-auth).

## Add a worker

Inside the VM (or via `colima ssh -- sudo ...`):

```bash
sudo bash /Users/.../ai-over-nats/scripts/sandbox/add-worker.sh raj
sudo systemctl start team-alpha-worker@raj
```

`add-worker.sh` creates `ta-worker-raj`, `mkdir /work/workers/raj`, enables the templated unit. Re-runs are idempotent.

## Start coord

```bash
sudo systemctl start team-alpha-coord
journalctl -u team-alpha-coord -f
```

## Verify

```bash
# AppArmor active
sudo aa-status | grep team-alpha
#   team-alpha-coord  (enforce)
#   team-alpha-worker (enforce)

# Profile attached to running process
cat /proc/$(pgrep -u ta-worker-raj -f claude)/attr/current
#   team-alpha-worker (enforce)

# DAC isolation
sudo -u ta-worker-raj cat /work/workers/lin/anything   # → permission denied
sudo -u ta-worker-raj cat /work/coord/anything         # → permission denied

# Negative tests
sudo -u ta-worker-raj cat /etc/shadow                  # → permission denied
sudo -u ta-worker-raj cat /home/$USER/.ssh/id_rsa      # → permission denied
sudo journalctl -k | grep apparmor=\"DENIED\"

# Positive
sudo -u ta-worker-raj git -C /work/workers/raj clone <project> repo
sudo -u ta-worker-raj nats-cli pub --token "$(cat /etc/team-alpha/nats-token)" \
     -s nats://127.0.0.1:4222 evt.coord-in.heartbeat '{}'
```

## Modes

First deploy: harvest real accesses with `complain` mode, then promote.

```bash
TA_AA_MODE=complain bash scripts/sandbox/colima-up.sh
# exercise harness for a few cards
sudo aa-logprof    # interactive: promote rules, save profile
TA_AA_MODE=enforce  bash scripts/sandbox/colima-up.sh
```

## Tear-down

```bash
colima delete --profile team-alpha --force
```

The VM is the trust boundary — deleting it deletes all worker state and worktrees. Project files on the host are untouched (mount only).

## Tuning

| Knob | Where | Default |
|---|---|---|
| vCPU / RAM / disk | `TA_CPU` / `TA_MEMORY` / `TA_DISK` | 4 / 8 / 40 |
| AppArmor mode | `TA_AA_MODE` | `enforce` |
| NATS endpoint | `/etc/team-alpha/nats.conf` | `127.0.0.1:4222` (loopback) |
| Profile name | `TA_PROFILE` | `team-alpha` |

## Multi-repo

team-alpha commonly drives **N downstream repos** from one harness checkout. The sandbox is built for it: workers operate across repos without mutating the host.

**Mount pattern.** `colima-up.sh` mounts `~/Repos` (or `$TA_REPOS`) **read-only** into the VM by default. Workers and coord see every repo at the same absolute path inside the VM (`/Users/<you>/Repos/<repo>` on macOS hosts). Workers cannot write back.

**Per-card flow.** See Card 225 (`team-alpha-sandbox-multirepo-worktree-flow.md`) for the full bootstrap path:

```
host ~/Repos/myproj  ──ro──► VM /Users/<you>/Repos/myproj      (read-only, "host" remote)
                                       │
                                       │ git clone --shared (hardlinks)
                                       ▼
                            /work/workers/raj/myproj/        (rw local clone, owned by raj)
                                       │
                                       │ git worktree add
                                       ▼
                            /work/workers/raj/myproj.worktrees/<slug>/    (per-card branch raj/<slug>)
                                       │ edit, commit, push
                                       ▼
                            origin = GitHub URL inherited from the host repo
                                       ▼
                                    PR opened
                                       ▼
                            coord reviews via per-user ACL on /work/workers/raj/
                                       ▼
                            PR merged on GitHub
                                       ▼
                            host runs `git fetch && git pull` to catch up
```

**Why read-only host mount.** Inside the VM, virtiofs presents the macOS filesystem under one UID. AppArmor cannot scope per-worker writes against that single shared path. If you mount rw, *every* worker can write *every* host repo — which defeats per-worker isolation. Keep `~/Repos` ro; do all work in `/work/workers/<name>/`. Code re-enters the host only via merged PRs.

## Allowlist posture (default since Card 230)

The shared profile **does not** grant a broad `/Users/** r,`. Workers see no repo under `/Users/$USER/Repos/` unless an explicit allow rule grants read on it. New repos cloned to `~/Repos` are invisible to workers until policy is updated and `team-alpha-apparmor sync --reload` (or the host watcher from Card 229) re-runs.

`team-alpha-apparmor sync` emits **allow** rules for repos matching `allow_orgs` and **deny** rules for `deny_orgs` / `deny_no_remote`. The denies are redundant under the default-deny shared profile; they ship as a tripwire — if someone re-introduces a broad allow in the base profile, the explicit denies still bite.

To run in legacy blocklist mode (broad allow, carve back), drop a personal `~/.team-alpha/apparmor/base` containing `/Users/** r,` and re-load. Not recommended.

## Personal AppArmor overrides

Each operator can tighten or extend the shared profile with rules kept **outside the repo**. AppArmor's `#include if exists <local/...>` mechanism lets you deny extra paths (e.g. a sensitive repo under `~/Repos`) or allow a non-standard tool, without committing your local policy.

**Where to edit on host:**

```
~/.team-alpha/apparmor/base      → /etc/apparmor.d/local/team-alpha-base    (rules in shared abstraction)
~/.team-alpha/apparmor/coord     → /etc/apparmor.d/local/team-alpha-coord   (coord-only)
~/.team-alpha/apparmor/worker    → /etc/apparmor.d/local/team-alpha-worker  (workers)
```

`colima-up.sh` mounts `~/.team-alpha/apparmor` ro into the VM and `install-in-vm.sh` syncs the files into `/etc/apparmor.d/local/`. After editing, either rerun `colima-up.sh` or, faster:

```bash
colima ssh --profile team-alpha -- sudo bash /Users/.../scripts/sandbox/reload-apparmor.sh
```

**Deny example.** Block worker access to a private repo while keeping the rest of `~/Repos` readable:

```
# ~/.team-alpha/apparmor/worker
deny /Users/me/Repos/secret-thing/    rwklx,
deny /Users/me/Repos/secret-thing/**  rwklx,
```

Note both forms — AppArmor's `**` glob does **not** match the directory entry itself, so `ls /path/` still works without the dir-level deny.

**Allow example.** Add a tool not in the base abstraction:

```
# ~/.team-alpha/apparmor/base
/opt/my-custom-tool/** rix,
```

**Rules:**

- `deny` always wins. Local file can tighten (deny extra) but cannot weaken a base deny.
- Mounts attach only on initial VM start. To activate `TA_LOCAL_APPARMOR` on an already-up VM: `colima delete --profile team-alpha --force && colima-up.sh`.
- The profile must be reloaded after every edit. The harness ships `scripts/sandbox/reload-apparmor.sh` for that.

## Auto-resync on repo clone (host watcher)

`team-alpha-apparmor sync` is manual. Easy to forget after cloning a new repo, opening a window where the new repo is allowed (in blocklist mode) or invisible (in allowlist mode) while reality and policy disagree.

The harness ships a tiny macOS LaunchAgent that watches `$TEAM_ALPHA_REPOS_ROOT` (default `~/Repos`) and runs `team-alpha-apparmor sync --reload` on every change.

```bash
team-alpha-apparmor watch install     # registers LaunchAgent + loads it
team-alpha-apparmor watch status      # is it loaded?
team-alpha-apparmor watch uninstall   # unloads + removes plist
```

Layout:

| File | Path |
|---|---|
| Plist | `~/Library/LaunchAgents/com.team-alpha.apparmor-watcher.plist` |
| Watcher script | `<harness>/scripts/host/apparmor-watcher.sh` |
| Watcher log | `~/.team-alpha/apparmor-watcher.log` |
| LaunchAgent stdout/stderr | `~/.team-alpha/apparmor-watcher.launchd.log` |

`ThrottleInterval=10` in the plist caps relaunches; the watcher script adds an internal 5-second debounce on top so back-to-back fires from `git clone`'s atomic rename collapse into one sync.

LaunchAgents start with a minimal PATH; the watcher script extends it to `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` so `colima`, `git`, etc. resolve.

macOS only. On Linux hosts use an inotify variant (out of scope).

## What this does **not** do

- Network egress allowlist. AppArmor cannot match by host:port. Add `nft` rules in `/etc/nftables.conf` if you want to pin worker outbound to GitHub + git remotes only.
- Interactive Allow/Deny prompts. AppArmor is silent kernel enforcement. See Card 232 (`team-alpha-human-gated-access-prompts.md`) for the seccomp-notify supervisor.
- Per-card path scoping. AppArmor profiles are static; they can't tell card A from card B. Landlock from inside the worker can — out of scope for this base.
- Protect against kernel exploits. The VM is the last line; if the worker escapes the kernel, it's still in a VM, not on the host.

## Portability

Profiles + units are arch-agnostic. Same files work on x86_64 Ubuntu, arm64 Ubuntu, bare-metal Linux, cloud VMs. Only `colima-up.sh` is macOS-specific; on Linux hosts run `install-in-vm.sh` directly on the target.
