---
column: Backlog
created: 2026-04-27
order: 232
priority: low
parent: team-alpha-sandbox-arm-colima-apparmor
depends_on: team-alpha-sandbox-arm-colima-apparmor
runtime: Linux ≥5.7 (eBPF LSM) or seccomp-notify capable kernel
---

# Card 232 — Human-gated access prompts on top of AppArmor sandbox

Port from `~/Repos/ai-fleet-harness/.tasks/human-gated-access-prompts.md`.

AppArmor is silent kernel enforcement — no popups. Add an
interactive layer so a human can approve or deny ambiguous
accesses (paths or hosts not in the static profile) at runtime,
without rewriting the AppArmor profile mid-flight.

Sits **on top of** the base sandbox (Card 224). AppArmor stays the
hard floor (deny obvious out-of-scope, silent). This card adds an
**opt-in middle band**: a "prompt zone" of paths/hosts that pause
the worker and surface a Y/N review event on the substrate bus.

## Goal

Per-worker supervisor that:

1. Wraps `claude` (and child `git`, `node`) via `seccomp-notify`
   (`SECCOMP_RET_USER_NOTIF`).
2. Filters configurable syscalls — `openat`, `connect`, `execve`
   — against an allow/deny/prompt policy.
3. On `prompt`: emits NATS event `evt.coord-in.access_request`
   with worker, syscall, resolved arg (path or host:port), pid,
   timeout.
4. Coord renders queue (TUI + optional web view), human clicks
   Allow/Deny.
5. Supervisor receives verdict via `evt.worker-in.access_grant`,
   replies to kernel within timeout. Default on timeout: deny.
6. Decisions optionally **memoized** for the card's lifetime (so
   "yes read /work/shared/foo.md" doesn't re-prompt 50x).

## Deliverables

- `worker-agent/sandbox/supervisor/` — Go (or Rust) binary
  `team-alpha-supervisor`:
  - parses `sandbox-policy.toml` (allow/deny/prompt globs +
    host:port lists).
  - sets up seccomp filter with `SECCOMP_RET_USER_NOTIF` for
    `openat`, `connect`, `execve`.
  - reads notif fd, peeks args via `/proc/<pid>/mem` +
    `SECCOMP_IOCTL_NOTIF_ID_VALID` race-safe pattern.
- NATS protocol: `evt.coord-in.access_request` +
  `evt.worker-in.access_grant` schemas in `schemas/`.
- Coord-side: TUI prompt queue.
- systemd integration: worker units exec via supervisor.

## Acceptance

- Worker tries `openat("/Users/me/private")` (in `prompt` zone) →
  supervisor pauses syscall, NATS event fires, coord TUI prompts,
  human Allow → openat returns the fd. Total latency <500ms on a
  warm path.
- Deny/timeout → openat returns EACCES.
- Memoization: same path inside one card-id → no re-prompt.
- AppArmor still wins: a path denied by the static profile never
  reaches the supervisor.

## Non-goals

- Not a replacement for AppArmor.
- Not fanotify/FUSE (too slow, breaks git).
- Not eBPF-LSM yet (kernel-version-fussy on default colima image).
- Not a generic policy engine — only per-worker, substrate-scoped.
