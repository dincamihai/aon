---
column: Backlog
created: 2026-04-27
order: 247
priority: medium
parent: team-alpha-meta-aon-cli
depends_on: team-alpha-aon-creds, team-alpha-aon-launch
---

# Card 247 — `aon join` — joiner-side replacement for `scripts/join.sh`

Today joiner clones BOTH the substrate repo AND the engine
repo, then `bash ~/Repos/ai-over-nats/scripts/join.sh <role>
<work-repo>`. Two clones is friction; engine path is
hardcoded; the script does many things at once.

## Goal

After installing the engine globally (`pipx install`-equivalent
or `~/.local/bin/aon` symlink — Card 249), joiner clones only
the substrate repo:

```bash
git clone <substrate-repo-url> ~/Repos/<team>-aon
cd ~/Repos/<team>-aon
aon join <role> <work-repo>
# → password prompt (out-of-band), saves creds, stamps work-repo, smokes auth
cd <work-repo> && claude
```

Or, with `aon launch` integration (Card 241), even shorter:

```bash
git clone <substrate-repo-url> ~/Repos/<team>-aon
cd ~/Repos/<team>-aon
aon launch <role> <work-repo>      # join + launch in one
```

## Behavior

`aon join` ports `scripts/join.sh`'s logic but reads paths from
aon.toml + engine install:

- prompts for password (or reads from stdin if piped from
  password manager)
- writes `~/.team-alpha/<role>.password` (chmod 600)
- runs the same `.claude/settings.json` + `.mcp.json` stamping
  pipeline
- verifies NATS handshake
- prints next-step

## Acceptance

- Engine on PATH + substrate repo clone + `aon join vahid
  ~/Repos/work` produces a launchable work repo.
- No manual `bash $ENGINE/scripts/join.sh` invocation needed.
- Existing `scripts/join.sh` retained for one release as a
  shim that calls `aon join`.

## Why

Removes the "joiner needs to clone the engine repo" step.
