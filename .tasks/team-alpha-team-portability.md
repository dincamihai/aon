---
column: Backlog
created: 2026-04-26
order: 223
---

# Card 223 — Meta-project: ai-over-nats as installable substrate engine

`ai-over-nats` should not be a repo each team forks. It should be
a **meta-project** — an installable engine + CLI tool that teams
or orgs drop into their own repo and onboard with. Like git,
pre-commit, terraform, or pulumi: one tool, many users, each user
keeps their data + config in their own repo.

Today the engine code, the team-alpha config, the team-alpha
docs, and the team-alpha task cards all live in this same repo.
That's a happy POC accident, not a sustainable shape.

## End-state shape

```
~/Repos/ai-over-nats/                    ← engine repo
  src/aon/                               ← Python package, CLI
  src/aon/templates/team.toml.example
  src/aon/templates/agent-prompts/*.md
  src/aon/scripts/{bootstrap,onboard,join}.sh
  src/aon/hooks/*.sh
  pyproject.toml                         ← installable: pipx install aon
  README.md                              ← engine docs

~/Repos/team-saas-aon/                   ← per-team / per-org repo
  aon.toml                               ← team config (committed
                                           or gitignored per team's
                                           security posture)
  agent-prompts/<role>.md                ← per-team role briefs
  agents/<role>.json                     ← per-team skill maps
  nats/auth.conf                         ← gitignored, team's secrets
  .tasks/                                ← team's task cards
  docs/                                  ← team's runbooks
```

## CLI verbs (the `aon` command)

```
aon init                         # in a team repo: scaffold aon.toml
                                 # + agent-prompts/ + .tasks/ + a
                                 # gitignore line for auth.conf

aon role add <name>              # interactive: skills, brief
                                 # template, persona scaffold,
                                 # NATS user + permissions in
                                 # auth.conf, password generated.

aon role list                    # show roles + assignments

aon role rotate <name>           # generate a new password,
                                 # update auth.conf, SIGHUP nats,
                                 # print distribution block.

aon bootstrap                    # NATS streams + KV bucket per
                                 # team config (idempotent).

aon onboard <role> <work-repo>   # joiner-side: stamps
                                 # .claude/settings.json + .mcp.json
                                 # into <work-repo>, saves creds,
                                 # probes substrate. (Today's
                                 # scripts/join.sh logic.)

aon nats up                      # docker compose up the substrate
                                 # using the team's nats-server.conf.

aon nats tunnel                  # cloudflared tunnel using the
                                 # team's [hub] config.

aon doctor                       # diagnostics: substrate reachable,
                                 # creds present, hooks installed,
                                 # MCP servers registered, role brief
                                 # loaded.

aon upgrade                      # bump the engine: new templates
                                 # diffed against the team's brief
                                 # files (3-way merge, conflict
                                 # markers — never auto-clobber).
```

`aon` is idempotent across the board — running any verb twice
gives the same result.

## Team repo layout (after `aon init`)

```
team-saas/
├── aon.toml                ← name, account, hub URL, role list
├── agent-prompts/
│   ├── _common.md          ← copied from engine, team can edit
│   └── <role>.md           ← one per role, scaffolded by `aon role add`
├── agents/
│   └── <role>.json         ← skill maps
├── nats/
│   ├── nats-server.conf    ← from engine template
│   ├── auth.conf.example   ← committed
│   └── auth.conf           ← gitignored (real passwords)
├── .tasks/                 ← team's kanban
├── docs/                   ← team's runbooks (engine ships defaults)
└── docker-compose.yml      ← from engine template
```

`aon.toml` example:

```toml
[team]
name = "team-saas"
nats_account = "team-saas"
kv_bucket = "team-saas-state"

[hub]
url = "wss://nats.saas.example.com"
local_port = 4222
ws_port = 8080

[engine]
version = ">=0.3,<0.4"   # pin compatible engine majors

# Roles defined separately in agents/<role>.json — `aon role add`
# writes them, `aon.toml` just references the directory.
```

## Distribution

- **Python**: `pipx install ai-over-nats` (PyPI). The `aon`
  command lands on PATH.
- **Optional npm**: `npx @ai-over-nats/cli` for joiners who don't
  want a Python install. Thin wrapper around the same logic.
- **Homebrew tap** (later): `brew install ai-over-nats` once
  there's enough adoption.

## Slices

### Slice 1 — Carve out engine vs. team-alpha config

Inside the current repo, separate cleanly:

- `src/aon/` — engine code (move scripts/, hooks/, mcp-server/
  here)
- `team-alpha/` — current team config (move agent-prompts/,
  agents/, nats/auth.conf*, .tasks/, docs/team-* here)

Two subdirs in one repo. Sets up the future split without doing
it yet.

### Slice 2 — `aon` CLI scaffold

- Wrap existing shell scripts behind a Python `click`/`typer`
  CLI: `aon init`, `aon onboard`, `aon nats up`, `aon doctor`.
- Each verb just shells out to the existing scripts initially.
  Refactor incrementally.

### Slice 3 — `aon role add / list / rotate`

- New verbs that own the team.toml + agents/ + auth.conf
  surface. Replaces the bootstrap-prompt manual flow with a
  scripted command (the bootstrap prompt becomes a
  `aon role add --interactive --signal-source=obsidian,jira`).

### Slice 4 — Engine package + PyPI publish

- `pyproject.toml` builds `aon` package. CI publishes to PyPI
  on tag.
- Templates bundled as package data, extracted by `aon init`.

### Slice 5 — Repo split

- `ai-over-nats` repo keeps only `src/aon/` + tests + docs of
  the engine.
- `team-alpha-aon` repo created with team-alpha's data
  (agent-prompts/, agents/, .tasks/, nats/, docker-compose.yml).
- `team-alpha-aon` becomes the canonical "example team" linked
  from engine README.

### Slice 6 — `aon upgrade`

- Engine template versioning. `aon upgrade` diffs new templates
  against the team's brief files; emits 3-way merge with
  conflict markers if templates evolved underneath. Never
  auto-clobber team customizations.

## Migration for team-alpha

1. Slice 1 (in-repo carve-out) lands. Existing scripts still
   work via path aliases. No behavior change for tomorrow's
   session or any current session.
2. Slice 2 lands. `aon` CLI exists; old scripts kept as thin
   shims for transition.
3. Slice 3-4 land. `aon role add` works against team-alpha
   in-place.
4. Slice 5: extract team-alpha config to its own repo. Engine
   repo becomes lean.
5. Slice 6: stable upgrade path for any team that adopted the
   engine in the meantime.

Total: weeks of work, but deliverable in slices that each leave
the current session functional.

## Why this and not just "configurable"

A configurable repo (Card 223 v1 framing) still requires teams
to fork → drift → upstream merges become painful. A meta-tool
keeps the engine versioned + upgradable while teams own only
their data. Same pattern that makes git, pre-commit, terraform,
and pulumi ecosystems work.

## Acceptance

- [ ] In a fresh empty repo, `aon init` scaffolds a working
      team config in under 30s.
- [ ] `aon role add alice` walks the persona questionnaire,
      writes the brief + skill JSON + auth.conf user.
- [ ] `aon onboard <role> <work-repo>` does what
      `scripts/join.sh` does today.
- [ ] `aon doctor` catches: missing creds, unreachable
      substrate, missing hook installation, MCP registration
      mismatches.
- [ ] `aon upgrade` from version N to N+1 leaves team
      customizations intact; conflicts marked, not silently
      overwritten.
- [ ] Two teams (team-alpha, team-bravo) configured in two
      separate repos run side-by-side against the same hub
      (different accounts, isolated subject space).
- [ ] No engine code references `team-alpha` or
      `priya|raj|lin|sam|diego` literals.

## Out of scope

- Web UI / dashboard for `aon`.
- Multi-team SaaS hosting model.
- AUDIT history migration across team renames (start fresh).
- Cross-team subject mesh (orgs run separate hubs).

## Refs

- Card 220 — post-MVP delegate + SDK; the SDK entrypoint also
  lives in the engine package.
- Card 222 — substrate HA; engine rename should land before
  Stage 2 hub migration.
- Card 215 — multi-role task cards; assumes generic role naming.
- `nsc-jwt-migration.md` — JWT migration also touches account
  name; sequence with Slice 5 carefully.

## Sequence note

Do **not** start any of this before tomorrow's team-alpha
session. Slice 1 (in-repo carve-out) is the earliest entry
point and a 1-day refactor; everything builds on that. Sequence
relative to other big cards:

1. Tomorrow's session lands (Card 221).
2. Slices 1-4 of this card.
3. Card 222 Stage 2 (hub off laptop, NSC JWT).
4. Slice 5 of this card (repo split).
5. Card 220 (post-MVP delegate + SDK).
6. Slice 6 + ongoing engine versioning.
