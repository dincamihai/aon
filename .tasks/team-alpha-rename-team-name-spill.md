---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 120
priority: high
parent: team-alpha-team-portability
---

# Rename "team-alpha" team-name spill across the engine

`team-alpha` was the prototype team name. It leaked into engine
identifiers that should be team-agnostic:

- Python package: `mcp-server/src/team_alpha_mcp/`
- pyproject entry point: `team-alpha-mcp`
- MCP tool prefix exposed to claude: `mcp__team_alpha__*`
- Hook env vars: `TEAM_ALPHA_{ROLE,NATS_URL,CREDS,KV_BUCKET,WORK_REPO}`
- Hook scripts referencing those vars
- Prompt templates referencing those vars

Real teams (e.g. `team-saas`) shouldn't carry `team_alpha` strings.

## Goal

Rename to engine-neutral identifiers under the `aon` namespace. Team
identity travels in `aon.toml` (`[team] name`) and the registry path
(`~/.aon/teams/<team>/`), not in code.

## Scope

| Old                               | New                          |
|-----------------------------------|------------------------------|
| `mcp-server/src/team_alpha_mcp/`  | `mcp-server/src/aon_mcp/`    |
| pyproject `team-alpha-mcp` script | `aon-mcp`                    |
| MCP tool prefix `mcp__team_alpha__*` | `mcp__aon__*`            |
| `TEAM_ALPHA_ROLE`                 | `AON_ROLE`                   |
| `TEAM_ALPHA_NATS_URL`             | `AON_NATS_URL`               |
| `TEAM_ALPHA_CREDS`                | `AON_CREDS`                  |
| `TEAM_ALPHA_KV_BUCKET`            | `AON_KV_BUCKET`              |
| `TEAM_ALPHA_WORK_REPO`            | `AON_WORK_REPO`              |
| `TEAM_ALPHA_BOARD_DIR` env        | `AON_BOARD_DIR`              |

Also:
- `.mcp.json` written by `aon join` uses neutral server keys
  (`aon`, `aon-board`) and an `aon mcp-server <name>` launcher
  (host-portable, no absolute paths). Adds `cmd_mcp_server` in
  `bin/aon` that dispatches to the engine's installed binary.
- `aon doctor` checks the new paths/vars.

## Files to touch (sweep)

Run before edit:

```sh
grep -rln 'team_alpha\|team-alpha\|TEAM_ALPHA\|TEAM_ALPHA_' \
  bin/ scripts/ mcp-server/ templates/ docs/ aon_engine/ infra/ \
  | grep -v '.tasks/' | grep -v 'caveman'
```

Expected hits: bin/aon, bin/_aon-lib.sh, scripts/hooks/*, mcp-server/src/team_alpha_mcp/*, templates/agent-prompts/*, templates/auth/* (account placeholder), pyproject.toml.

## Migration / backwards compat

Hard cut. Operators bounce NATS + re-run `aon join-link` once.
- Joiners with old `<role>.env` (TEAM_ALPHA_*) need re-join. Cheap.
- Old MCP entries `team-alpha`, `team-alpha-board` in
  `~/.claude/settings.json` get cleaned up by `_aon_install_repo_mcp`
  (delete legacy keys before writing the new `.mcp.json`).
- aon.toml `[team] account` placeholder stays — that's a NATS
  account name, not engine identifier.

## Acceptance

- `grep -r 'team_alpha\|team-alpha\|TEAM_ALPHA' bin/ scripts/
   mcp-server/ templates/ aon_engine/` returns empty.
- Fresh `aon init && aon onboard X bits` writes a `.mcp.json` with
  `aon` + `aon-board` keys; commands are `aon` + args; no operator
  homedir paths.
- Joiner `aon join-link` works without re-rendering prompts manually.
- mihai's claude session (operator) sees `mcp__aon__*` tools, NOT
  `mcp__team_alpha__*`.
- Hooks fire correctly (session-start handshake, catch-up,
  user-prompt-submit) reading `AON_ROLE`/`AON_NATS_URL`/etc.

## Out of scope

- Renaming the registry dir layout (`~/.aon/` is already neutral).
- `aon.toml` `[team] account` placeholder default — separate cosmetic.
- KV bucket name `team-state` → `aon-state` rename (would invalidate
  existing buckets; defer).
