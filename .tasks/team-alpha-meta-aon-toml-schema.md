---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 236
priority: medium
parent: team-alpha-team-portability
---

> **Status (2026-04-27, slice 1 shipped):** schema v0.1 lives at
> `templates/aon.toml.example`. Sections: `[engine]`, `[team]`,
> `[nats]`, `[[roles]]`, `[paths]`, `[repos]`. Loader in
> `bin/_aon-lib.sh` parses via awk (no Python/Toml dep). CLI uses
> it through `aon_load_config` in every subcommand.

# Card 236 — Meta: define `aon.toml` schema (single source of truth)

Per-team repo holds an `aon.toml`. Every renderer (Cards 234, 235),
the `aon` CLI (Card 233), bootstrap.sh, hooks read from it. No more
hard-coded `maya raj lin sam diego priya` lists across scripts.

## Schema (proposed)

```toml
[engine]
version       = "0.1"      # schema version, bumps on breaking changes

[team]
name          = "team-alpha"
account       = "team-alpha"
kv_bucket     = "team-state"
subject_prefix = "org.team-alpha"   # optional; default = "org.<team-name>"

[nats]
url           = "nats://localhost:4222"   # local default
ws_url        = "wss://nats.example.com"  # for joiners over cloudflared
admin_user    = "sysadmin"

[[roles]]
name     = "mihai"
kind     = "manager"
domain   = "manager"

[[roles]]
name     = "raj"
kind     = "generalist"
domain   = "python"
learning = "go"

[[roles]]
name     = "priya"
kind     = "specialist"
domain   = "terraform"
learning = "python"

[paths]
task_dir       = ".tasks"
prompts_dir    = "scripts/agent-prompts"
agents_dir     = "agents"
hooks_dir      = "scripts/hooks"

[repos]
default = "ai-over-nats"
known   = ["ai-over-nats", "exasol-saas"]
# repos_root = "/Users/$USER/Repos"   # override default
```

## Deliverables

- `templates/aon.toml.example` — annotated reference.
- `_load_config` helper in `bin/_aon-lib.sh` parses the file (awk-based).
- Documented in `docs/aon-toml.md`.
- Schema version field — bumps on incompatible changes; CLI checks +
  refuses if mismatch.

## Acceptance

- `aon doctor` reads aon.toml and validates required sections.
- Other CLI subcommands (Cards 233-235) consume the parsed values.
- Reference: fleet-harness uses `ai-fleet.toml` — similar shape.

## Why

Currently every script that wants to know "which roles exist" greps
the bootstrap script or hard-codes the list. With one source of
truth, adding/removing a role becomes an edit to a single file +
re-render.
