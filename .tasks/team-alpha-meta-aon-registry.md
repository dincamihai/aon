---
column: Backlog
created: 2026-04-27
order: 1070
priority: high
parent: team-alpha-team-portability
depends_on: team-alpha-meta-engine-vs-team-split
---

# Card — MCP resolves team from cwd, drop work-repo stamping

## Context

Today `aon join-link` stamps three files into each work-repo:

- `.mcp.json` — MCP server config with baked env vars (NATS URL, role, creds path)
- `.claude/settings.json` — hooks with env vars baked in
- `CLAUDE.md` — symlink to role brief

This couples every git repo to a specific role+team at join time. Baked env vars mean URL rotation must patch `.mcp.json` and `settings.json` in every work-repo. A joiner with multiple repos / multiple teams gets multiple stamps to maintain.

The MCP server itself has zero cwd or git awareness today (`mcp-server/src/team_alpha_mcp/__main__.py` `_load_env()` lines 39–56) — it reads four env vars baked at server-start time.

It also produces operational footguns:

- Running `aon nats up` from `$HOME` makes `project=basename($HOME)` (e.g. `mid`), the compose file falls back to engine's, and the resulting `mid-nats-1` orphan squats `:4222` — blocking later `aon onboard` from the real team dir. Hit live, see commit `6eb8f19`.
- Operator must `cd ~/Repos/team-aon` before `aon onboard`; joiner must `cd` somewhere right before `aon join-link`. There's no reason — both could resolve from a registry.
- State lives at `~/.team-alpha/<role>.{password,env}` with the team name baked in, blocking multi-team joiners (e.g. john on team-alpha + team-beta).

NATS auth is the actual access boundary (server-enforced user+pw + subject permissions per role). The aon registry below is purely ergonomic — a cwd→(team, role) hint. It is not a security layer. Wrong inference fails loud at the NATS handshake.

The MCP server inherits claude's cwd at startup. If it resolves team+role+NATS from a registry keyed on cwd, no per-repo stamping is needed. Global MCP config + global hooks cover all repos on the machine.

## What changes

### 1. `~/.aon/` registry

```
~/.aon/
  work-repos.json            # canonical index: realpath → {team, role}
  teams/
    team-alpha/
      repo/                  # team-aon checkout (was $AON_TEAM_DIR)
      creds/
        john.password        # chmod 600
        john.env             # NATS URL cache + work-repo hint
        vahid.password
```

`work-repos.json`:

```json
[
  {"path": "/Users/mid/Repos/saas-john",  "team": "team-alpha", "role": "john"},
  {"path": "/Users/mid/Repos/other-john", "team": "team-beta",  "role": "john"}
]
```

Written by `aon join-link`. Used by CLI + MCP server for cwd resolution.

### 2. Resolution order (every command + MCP server)

1. `--team NAME [--role NAME]` flag (CLI only; explicit override).
2. cwd → walk to git toplevel → look up in `work-repos.json` → resolve.
3. Only one team registered on this host → use it.
4. Fall back to env vars (back-compat for existing stamped repos during migration).
5. Otherwise: fail with listing of registered (path → team/role) entries.

### 3. MCP server: cwd → registry at startup

**Files:** `mcp-server/src/team_alpha_mcp/__main__.py` `_load_env()` (lines 39–56), `mcp-server/src/team_alpha_mcp/client.py` `TeamAlphaClient.__init__()` (~line 95).

Change `_load_env()`:

1. Read own `cwd` (`os.getcwd()`); walk to git root.
2. Load `~/.aon/work-repos.json`, find entry matching cwd path.
3. If found → derive team, role, creds path (`~/.aon/teams/<team>/creds/<role>.{password,env}`).
4. Fallback: read `TEAM_ALPHA_ROLE` / `TEAM_ALPHA_NATS_URL` / `TEAM_ALPHA_CREDS` / `TEAM_ALPHA_KV_BUCKET` (back-compat).
5. `ROLE` module constant + NATS connection params resolved as today; caller sees no change.

No change to subject construction, tool surface, ACL logic, or KV handling.

### 4. Global MCP + hooks install (no per-repo .mcp.json / settings.json)

**File:** `bin/aon` `cmd_join` (lines 672–779) — hollow out stamping section. New helper `_aon_install_global_mcp()`.

`aon join-link` (and `aon join`) instead:

- Writes creds to `~/.aon/teams/<team>/creds/`.
- Appends/upserts `(path, team, role)` entry in `work-repos.json`.
- Calls `_aon_install_global_mcp()` once (idempotent: skip if already installed for this engine path):
  - Writes/merges `team-alpha` MCP server entry into `~/.claude/settings.json`.
  - Writes/merges hooks (env-free since env comes from registry at runtime) into `~/.claude/settings.json`.
  - No env vars baked — MCP server reads them from registry.

### 5. Role brief via MCP tool instead of CLAUDE.md symlink

Add `get_role_brief()` tool to MCP server (`__main__.py`):

- Reads `~/.aon/teams/<team>/repo/<AON_PROMPTS_DIR>/<role>.md` (or engine fallback).
- Returns markdown content.
- Agent calls it on first turn (instruction in global `~/.claude/CLAUDE.md`).

Global `~/.claude/CLAUDE.md` (written once by `_aon_install_global_mcp()`):

```markdown
# team-alpha agent

Call `get_role_brief()` on your first turn to load your role context.
```

No per-repo CLAUDE.md symlink needed.

### 6. `aon set-nats-url` simplifies

**File:** `bin/aon` `cmd_set_nats_url` (lines 1166–1225).

- Updates `~/.aon/teams/<team>/creds/<role>.env` (NATS URL field).
- NO `.mcp.json` / `settings.json` patching per repo (they no longer contain the URL).
- MCP server reads fresh URL from registry on next startup.

`_aon_apply_nats_url()` shrinks: drop the `.mcp.json` jq patch and the `settings.json` gsub — just the env file update + handshake probe.

### 7. Other commands wired to resolver

- `aon nats up|down|logs`: cwd → resolve team → use `~/.aon/teams/<team>/repo/docker-compose.yml`. Project name = team name (kills the `mid-nats-1` footgun for good).
- `aon onboard <role> <bits>`: resolves team from cwd or `--team`. No more `cd team-aon`.
- `aon monitor [role]`: cwd → resolve role automatically.
- `aon doctor`: reports registry state, resolves cwd, lists known teams + work-repos.
- (no `aon team use`) — skipped per discussion (NATS dictates access; cwd resolution is enough).

## Files to modify

| File | Change |
|------|--------|
| `mcp-server/src/team_alpha_mcp/__main__.py` | `_load_env()`: cwd→registry + env var fallback; add `get_role_brief()` tool |
| `mcp-server/src/team_alpha_mcp/client.py` | Accept resolved values from `_load_env()` instead of reading env directly |
| `bin/aon` | `cmd_join` / `cmd_join_link`: replace stamping with `_aon_install_global_mcp()` + registry write; `cmd_set_nats_url`: drop `.mcp.json`/`settings.json` patching; `_aon_apply_nats_url`: shrink; add `_aon_install_global_mcp()`; wire `cmd_nats_*`, `cmd_onboard`, `cmd_monitor`, `cmd_doctor` to cwd resolver |
| `scripts/join-link.sh` | Same simplification: write creds + registry, no stamping |
| `README.md` | Update §2 joiner flow (no work-repo concept), §1 operator global install |

## Files NOT changed

- `mcp-server/src/team_alpha_mcp/subjects.py` — no change
- `mcp-server/src/team_alpha_mcp/acl.py` — no change
- `mcp-server/src/team_alpha_mcp/a2a/` — no change
- `aon.toml` schema — no change
- `templates/` — no change

## Verification

1. Fresh machine simulation:
   - `aon join-link <token> <bits>` from any dir
   - `~/.aon/work-repos.json` contains entry
   - `~/.claude/settings.json` has `team-alpha` MCP entry (no baked env vars)
   - `claude` from work-repo → MCP server starts → call `get_role_brief()` → returns correct brief
2. URL rotation: `aon set-nats-url <new-bits>` → updates only `~/.aon/teams/team-alpha/creds/*.env` → restart claude → MCP connects to new URL (no `.mcp.json` edits)
3. Two-team joiner: two work-repos registered for different teams → `cd repo-a && claude` → team-alpha MCP; `cd repo-b && claude` → team-beta MCP; same global settings.json, different registry entries
4. From `$HOME`: `aon nats up` → resolves team from cwd or fails loud (no team in registry, no cwd match), tells user how to register.
5. Operator: `aon onboard mihai <bits>` from `$HOME` (with team-alpha registered) → succeeds, cd not required.

## Out of scope (separate cards)

- Renaming `TEAM_ALPHA_*` env vars to `AON_*` (hooks + MCP server).
- Multi-team `aon nats up` (today only one team's NATS, since each team has its own tunnel anyway).
- `aon team use` default-team pin.
- Migration helper for existing `~/.team-alpha/` users — not needed; nobody using it yet.
