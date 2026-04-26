# team-alpha worker containers

Card 214 — worker isolation. Each role runs in its own OCI
container; the host stays clean. Maya stays on host in P1, joins
the container fleet in P2.

## Runtime: docker OR podman

Nothing here is docker-specific. `build.sh` and (future)
`team-alpha-spawn.sh` auto-detect:

```bash
CTR=$(command -v docker || command -v podman)
```

Override with `CTR=podman ./build.sh`.

## Layout

```
infra/worker-image/
  Dockerfile.base    — claude CLI, nats CLI, git, python3 + venv,
                       team-alpha-mcp installed, non-root `worker` user
  build.sh           — sha-tagged build, both `:<sha>` and `:latest`
```

All five worker roles run the same `team-alpha-worker-base` image.
`TEAM_ALPHA_ROLE` is set at run time via env, not bake time.
Per-role tooling overlays (`Dockerfile.<role>`) are deferred until
a real task actually needs role-specific binaries (terraform, awscli,
etc.) — current scenarios are simulated through Claude reasoning,
not real binary execution. Drop a `Dockerfile.<role>` next to the
base when that changes; `build.sh <role>` will pick it up.

## Apple Silicon note

Claude CLI ships native code that crashes ("Illegal instruction")
under QEMU x86 emulation. `build.sh` matches the image platform to
the runtime VM's architecture (not the host's), so build succeeds
on `colima default` (x86_64) without forcing arm64.

If you want native arm64 (faster, Claude CLI-stable), start an
arm64 colima profile and switch context:

```bash
colima start arm   # aarch64 VM
docker context use colima-arm  # or whatever colima registers
```

Then `./build.sh` picks up `linux/arm64` automatically.

## Build

```bash
./build.sh                  # base + every Dockerfile.<role>
./build.sh base             # base only
./build.sh <role> [...]     # base then named overlays (when defined)
```

The base image stages `mcp-server/` into a tempdir build context
so a repo-root edit doesn't invalidate the image cache. Role
overlays (when added) use `infra/worker-image/` as their build
context (small, fast).

## Auth — NEVER baked in

The image is auth-free. Mount at run time:

| Host path                              | Container path                  | Why                              |
|----------------------------------------|---------------------------------|----------------------------------|
| `~/.team-alpha/<role>.password`        | `/run/secrets/role-password:ro` | NATS user password               |
| `~/.team-alpha/anthropic-key`          | `/run/secrets/anthropic-key:ro` | Claude CLI auth                  |
| `<repo-root>/scripts/agent-prompts/<role>.md` | `/etc/team-alpha/role-prompt.md:ro` | role brief                |
| `<repo-root>/MODEL.md`                 | `/etc/team-alpha/MODEL.md:ro`   | substrate primer                 |

Per-task git worktree mount + per-role workspace mount land in
slice 3 (`team-alpha-spawn.sh`).

## Network

- NATS reachable at `host.docker.internal:4222` on Mac
  (Docker Desktop + podman both translate). Linux hosts: pass
  `--add-host host.docker.internal:host-gateway`.
- No outbound internet by default — slice 4 wires per-task egress
  allowlist.

## Status

- [x] Slice 1 — base image + build.sh (all roles share the base)
- [ ] Slice 2 — `compose.workers.yml` (one service per role,
      env-parameterized; same image)
- [ ] Slice 3 — `team-alpha-spawn.sh` (worktree + container
      lifecycle)
- [ ] Slice 4 — board-tui `--role` filter / wrapper, ACL mount split
- [ ] Slice 5 — role-prompt updates for container-only filesystem
- [ ] Future — per-role tooling overlays when a real task needs them
- [ ] P2 — maya in container

See `.tasks/team-alpha-worker-containers.md` (card 214) for the
full spec.
