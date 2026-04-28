---
column: Doing
created: 2026-04-28
order: 100
priority: normal
---

# Per-repo MCP install (replace global ~/.claude/settings.json write)

`aon join` / `aon onboard` currently install the `team-alpha` and
`team-alpha-board` MCPs into `~/.claude/settings.json` (global). This
leaks team MCP into every Claude session on the host, even repos that
have nothing to do with team-alpha.

## Goal

Install MCP servers into the **work-repo's** `.mcp.json` (or
`.claude/settings.local.json`) instead of global settings. Every Claude
session opened from the work-repo picks up the team-alpha MCP; sessions
opened anywhere else don't.

## Scope

- Edit `_aon_install_global_mcp()` in `bin/aon` (~line 1024):
  - Drop the global `~/.claude/settings.json` write for `mcpServers`.
  - Write `<work_repo>/.mcp.json` instead, merging with existing keys
    (don't clobber).
  - Keep CLAUDE.md fenced block (per-repo already).
  - Hooks: keep global for now (resolved via `aon resolve-env`) — out
    of scope for this card.
- Rename helper: `_aon_install_global_mcp` → `_aon_install_repo_mcp`.
- Update callers (`cmd_join` line 1279, `cmd_join_link` line 1721).

## Out of scope

- NSC/JWT migration (separate card).
- Hooks → per-repo (separate card if needed).
- Renaming `team-alpha` package itself.

## Acceptance

- Fresh `aon join NAME REPO` produces `<repo>/.mcp.json` with both
  `team-alpha` and `team-alpha-board` entries.
- `~/.claude/settings.json` mcpServers untouched (or only contains
  pre-existing user entries).
- Re-running `aon join` is idempotent (no duplicate keys).
- Claude session opened in `<repo>` lists `mcp__team_alpha__*` tools.
- Claude session opened OUTSIDE `<repo>` does NOT list them.
