---
column: Backlog
created: 2026-04-28
order: 110
priority: normal
parent: per-repo-mcp-install
---

# Per-repo hooks install (move from ~/.claude/settings.json to <work_repo>/.claude/settings.json)

The per-repo MCP install card moved `mcpServers` out of
`~/.claude/settings.json` into `<work_repo>/.mcp.json`. Hooks were
left global as scope cut. This card finishes the job.

## Problem

Today every claude session on the host triggers the team-alpha hooks
(session-start-onboard, session-start-catch-up, user-prompt-submit,
post-tool-context-refresh, post-tool-status-ping, pre-compact, stop,
session-end-goodbye). They no-op outside a registered work-repo
(`aon resolve-env` returns rc=1), but:

- Cost: each session pays the fork+exec for every hook.
- Side-effect risk: a hook bug could fire in unrelated dirs.
- Surprise: opening a non-team repo runs scripts the user didn't
  install for that project.
- Discoverability: nothing in an unrelated repo signals that
  team-alpha hooks are wired in.

Same blast-radius rationale as moving MCPs out of global settings.

## Goal

Install hooks into `<work_repo>/.claude/settings.json` (or
`<work_repo>/.claude/settings.local.json` if it should not be
committed). Sessions opened anywhere else don't run team-alpha hooks.

## Scope

- Edit `_aon_install_repo_mcp()` in `bin/aon`:
  - Drop the global `~/.claude/settings.json` write for `.hooks`.
  - Write hooks into `<work_repo>/.claude/settings.json`, merging
    with existing `.hooks` (don't clobber).
  - Keep the `eval $(aon resolve-env) && ...` wrapping (still needed
    so a hook fired from a worktree resolves the right
    team/role/url).
- Add a one-shot migration: on next run, REMOVE the previously-installed
  team-alpha hooks from `~/.claude/settings.json` so they don't
  double-fire alongside the per-repo install. Detect by command
  containing `aon resolve-env && bash` and the engine dir path.
- Decide commit policy:
  - Default: write to `.claude/settings.json` (committable). Joiners
    pulling team-aon get hooks for free, no install step.
  - Alternative: write to `.claude/settings.local.json` (gitignored).
    Joiners must run `aon join-link` to install hooks. More explicit
    consent, costs setup friction.
  Recommend committable: matches MCP `.mcp.json` model and joiners
  already trust the team-aon repo.
- Path baking: hook commands reference the engine repo on the
  operator's box (`bash /Users/mid/Repos/ai-over-nats/scripts/hooks/...`).
  Joiners pull a settings.json with operator's path. Same drift
  class we hit with `.mcp.json`. Either:
  - Resolve engine dir at runtime via `aon` on PATH:
    `aon-hook session-start-onboard` (engine adds a `hook` subcommand
    that dispatches to `$(aon-engine-dir)/scripts/hooks/<name>.sh`).
  - Or use `${AON_ENGINE_DIR}` env var with operator-side defaults
    in the shell rc.
  Recommend the `aon hook <name>` subcommand — single resolution
  point, no env-var dance, mirrors how `aon pub` already wraps the
  nats CLI.

## Out of scope

- Renaming `team-alpha` package itself (separate card).
- Deciding hook-handle for orphaned worktrees (current resolve-env
  no-op is fine).

## Acceptance

- Fresh `aon join NAME REPO` produces `<repo>/.claude/settings.json`
  with team-alpha hooks; `~/.claude/settings.json` `.hooks` no longer
  contains them.
- Re-running `aon join` is idempotent.
- Claude session opened in `<repo>` runs team-alpha hooks.
- Claude session opened OUTSIDE `<repo>` does NOT run them
  (verify via a hook that touches `/tmp/aon-hook-fired` and
  confirming the file is absent after sessions in unrelated dirs).
- `aon doctor` verifies per-repo settings.json presence + warns on
  stale global keys.
- Hook commands portable across hosts (no operator absolute paths
  baked into the committed file).
