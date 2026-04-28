---
column: Backlog
created: 2026-04-28
order: 200
priority: deferred
parent: onboarding-overhaul
depends_on: operator-spawn-helpers
---

# Headless agent spawn — main agent spawns helpers without operator

Adds main-agent-driven spawn on top of the human-in-the-loop
helper bus from `operator-spawn-helpers`. Lets the main agent
fan out parallel work without the operator opening N terminals.

**Deferred** until the human-in-the-loop variant lands and proves
the gateway pattern + worktree boundaries are sound. Don't
introduce auto-spawn until manual-spawn is solid.

## Why deferred

- Manual spawn = operator can stop the bleed by closing a tab.
  Auto-spawn = LLM mistake leaks subprocesses, tokens, disk.
- Need to validate the gateway / worktree / cred pattern first
  with the operator-driven flow.
- Operator UX for "see what main agent spawned" is a separate
  design problem (TUI? log file?).

## Builds on

Reuses primitives from `operator-spawn-helpers`:
- Local helper-bus + subjects.
- Worktree-per-helper at `~/.aon/helpers/<id>/wt/`.
- File / git boundaries.
- Discovery convention.

## Adds

- `aon spawn-helper` CLI (autonomous, no operator terminal).
- `spawn_helper(task, timeout, model)` MCP tool for main agent.
- Lifecycle state in KV (so main agent can resume helpers across
  its own restart).
- Per-parent cap (`AON_HELPER_MAX`).
- Timeout enforcement (subprocess gets SIGTERM after N).
- Orphan reaper (`aon cleanup-orphans`).
- Resource cap: refuse spawn over cap.
- Audit log: append-only on disk (not in NATS) with helper_id +
  task + outcome.

## Open questions

1. **Operator visibility**: how does operator see what main agent
   spawned? Tail a log? TUI? Notification? Required for trust.
2. **Cost ceiling**: per-day token spend cap before main agent
   refuses to spawn more.
3. **Cancel semantics**: main agent crashes mid-task. Operator
   resumes session — do orphan helpers continue or get reaped?
4. **Sandboxing strength**: human-in-loop has the human as the
   sandbox. Auto-spawn needs OS-level isolation (firejail / nsjail
   / docker / nothing) — pick one.

## Acceptance (when un-deferred)

- Main agent calls `spawn_helper(task)` → helper subprocess starts,
  worktree allocated, task delivered, result returned without
  operator action.
- Spawn over cap (`AON_HELPER_MAX=5`) refused with clear error.
- Timeout enforced: helper subprocess SIGTERM at N seconds.
- Orphan reaper handles main-agent-crash case.
- Operator can audit: `aon helper-log` shows recent auto-spawns.
- Cost ceiling honored: refuse spawn if est. spend > cap.

## Out of scope

- Replacing human-in-the-loop helpers — both modes coexist.
- Cross-host auto-spawn (helpers run on parent's box, like
  human-spawn).
- Sub-helper spawning by helpers (still ACL-denied).
