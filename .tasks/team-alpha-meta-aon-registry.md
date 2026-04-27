---
column: Backlog
created: 2026-04-27
order: 1070
priority: high
parent: team-alpha-team-portability
depends_on: team-alpha-meta-engine-vs-team-split
---

# Card — Replace `$AON_TEAM_DIR = cwd` with `~/.aon/` registry

## Problem

Today every `aon` command needs to know "which team checkout am I
working with." It infers this from `AON_TEAM_DIR`, defaulting to cwd.
That coupling produces three concrete bugs:

1. **Footgun:** running `aon nats up` from `$HOME` makes
   `project=basename($HOME)` (e.g. `mid`). The compose file falls
   back to engine's, and the resulting `mid-nats-1` orphan squats
   `:4222` forever — blocking later `aon onboard` from the real team
   dir. Hit live in this session, see commit `6eb8f19`.
2. **Onboard / join require cd:** operator must `cd ~/Repos/team-aon`
   before `aon onboard`; joiner must `cd` somewhere right before
   `aon join-link`. There's no reason — both could resolve the team
   from a registry.
3. **Multi-team blocked:** state lives at `~/.team-alpha/<role>.{password,env}`
   with the team name baked in. Joiner who's in multiple teams
   (e.g. john on team-alpha + team-beta) has no way to disambiguate.

NATS auth is the actual access boundary (server-enforced user+pw +
subject permissions per role). The aon registry below is purely
ergonomic — a cwd→(team, role) hint. It is not a security layer.

## Target shape

```
~/.aon/
  work-repos.json            # canonical index: realpath → {team, role}
  teams/
    team-alpha/
      repo/                  # the team-aon checkout (was $AON_TEAM_DIR)
      creds/
        john.password        # chmod 600
        john.env             # TEAM_*_NATS_URL, WORK_REPO, etc.
        vahid.password
        ...
    team-beta/
      repo/
      creds/john.{password,env}
```

`work-repos.json`:

```json
[
  {"path": "/Users/mid/Repos/saas-john",  "team": "team-alpha", "role": "john"},
  {"path": "/Users/mid/Repos/other-john", "team": "team-beta",  "role": "john"}
]
```

## Resolution order (every command)

1. `--team NAME [--role NAME]` flag (explicit override).
2. cwd → walk to git toplevel → look up in `work-repos.json` → resolve.
3. Only one team registered on this host → use it.
4. Fail with a listing of registered `(path → team/role)` entries.

NATS rejects wrong creds anyway, so a wrong inference at step 2 fails
loud at the handshake — no silent corruption.

## CLI surface

| Command                          | Behavior change                                     |
|----------------------------------|-----------------------------------------------------|
| `aon init`                       | Creates `~/.aon/teams/<team>/repo/` (or registers an existing checkout). Optional `--team NAME`. |
| `aon onboard <role> <bits>`      | Resolves team from cwd or `--team`. No more `cd team-aon`. |
| `aon join-link <token> <bits>`   | Token carries team name. Ensures `~/.aon/teams/<team>/repo/` exists (clone or pull). Writes creds to `~/.aon/teams/<team>/creds/`. Registers work-repo in `work-repos.json`. |
| `aon set-nats-url <bits>`        | cwd → resolve → rotate that team. Fall back to "all teams on this host" if cwd is unregistered. |
| `aon monitor [role]`             | cwd → resolve role automatically. |
| `aon nats up\|down\|logs`        | cwd → resolve team → use `~/.aon/teams/<team>/repo/docker-compose.yml`. Project name = team name (kills the `mid-nats-1` footgun). |
| `aon doctor`                     | Reports registry state, resolves cwd, lists known teams + work-repos. |
| (no `aon team use`)              | Skipped — NATS dictates access; registry is just a hint. cwd resolution covers the common case. |

## Migration

- One-shot helper: `aon migrate-registry` reads existing
  `~/.team-alpha/*.{password,env}` and copies them to
  `~/.aon/teams/team-alpha/creds/`. Reads each env file's
  `TEAM_ALPHA_WORK_REPO` and seeds `work-repos.json`. Does NOT delete
  the old dir on first run; prints `rm -rf ~/.team-alpha` when ready.
- New `aon` versions read the new layout but keep a deprecation-warn
  fallback to `~/.team-alpha/` for one cycle, so partial migration
  doesn't brick anything.
- `TEAM_ALPHA_*` env var names stay as-is for now (used by hooks +
  MCP server); rename to `AON_*` is a separate card.

## Touch points

- `aon_load_config`, `_aon_nats_compose`, `_aon_nats_project_name`
- `cmd_init`, `cmd_onboard`, `cmd_add_role`, `cmd_auth_*`, `cmd_creds`
- `cmd_nats_up|down|logs|status`
- `cmd_join`, `cmd_join_link`
- `cmd_set_nats_url`, `cmd_monitor`, `cmd_doctor`
- `bin/aon` help text + README §1 (operator) and §2 (joiner)
- `templates/docker-compose.yml.tmpl` — project name resolution
- `scripts/join-link.sh` — same registry write on standalone path

Add: `aon registry list`, `aon registry show <work-repo>`, `aon
migrate-registry` (one-shot).

## Smoke / acceptance

1. From `$HOME`: `aon nats up` → fails loud (no team in registry, no
   cwd match), tells user how to register.
2. `cd ~/Repos/saas-john && aon set-nats-url <bits>` → resolves to
   team-alpha + role john without flags.
3. Operator: `aon onboard mihai <bits>` from `$HOME` (with team-alpha
   registered) → succeeds, cd not required.
4. John joins team-beta on the same machine: token decode → registers
   `~/Repos/other-john` under `team-beta`. `cd other-john && aon
   monitor` → tails team-beta. `cd saas-john && aon monitor` → tails
   team-alpha. No flag needed.
5. `aon doctor` from outside any registered work-repo lists all known
   work-repos and points at unresolved cwd.

## Out of scope (separate cards)

- Renaming `TEAM_ALPHA_*` env vars to `AON_*` (hooks + MCP server).
- Multi-team `aon nats up` (today only one team's NATS, since each
  team has its own tunnel anyway).
- `aon team use` default-team pin — skipped per discussion (NATS
  dictates access; cwd resolution is enough for the joiner-in-many-teams
  case).
