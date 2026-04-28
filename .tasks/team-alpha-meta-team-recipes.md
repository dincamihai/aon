---
column: Backlog
created: 2026-04-28
order: 1090
priority: medium
parent: team-alpha-team-portability
depends_on: team-alpha-meta-auth-out-of-repo
---

# Card — Team + role recipes (pre-baked blueprints)

## Context

Today `aon init` ships a single hardcoded roster in `templates/aon.toml.example`. Until the auth-out-of-repo card landed, that template seeded 6 fake/sim names (raj/lin/sam/diego/priya/mihai) into every fresh team. We removed the placeholders, but the underlying problem stayed: there is no way to bootstrap a real team with a sensible default roster, and `aon onboard NAME BITS [KIND] [DOMAIN]` makes the operator guess `kind` + `domain` per role with no library to draw from.

Operators bringing up a new team should be able to say "this is an engineering team" and get a coherent baseline (PM + a couple backend engineers + frontend + SRE), with each role's kind/domain/learning + ACL + prompt knobs already correct. Same for a sales team, a PM org, a research squad, etc.

Recipes turn role + team shape into reusable, versioned artifacts.

## What changes

### Layout

```
templates/recipes/
  roles/
    backend-engineer.toml      # kind=specialist domain=python learning=go
    frontend-engineer.toml     # kind=specialist domain=ui      learning=python
    fullstack-engineer.toml    # kind=generalist  domain=fullstack
    sre.toml                   # kind=specialist domain=terraform learning=python
    eng-manager.toml           # kind=manager     domain=manager
    pm.toml                    # kind=manager     domain=product
    designer.toml              # kind=specialist domain=design
    sales-rep.toml             # kind=specialist domain=sales
    research-scientist.toml    # kind=specialist domain=research
  teams/
    engineering.toml           # PM + 2x backend + frontend + SRE
    sales.toml                 # head + 3x sales-rep
    research.toml              # PM + 3x researcher
```

### Role recipe (TOML fragment)

```toml
# templates/recipes/roles/backend-engineer.toml
[recipe]
id          = "backend-engineer"
description = "Server-side engineer; Python primary, Go growth."

[role]
kind     = "specialist"
domain   = "python"
learning = "go"

# optional — override default auth template (otherwise <kind>.tmpl)
# auth_template = "specialist-extended.tmpl"

# optional — prompt template id (otherwise <kind>.md.tmpl)
# prompt_template = "engineer.md.tmpl"
```

### Team recipe (TOML)

```toml
# templates/recipes/teams/engineering.toml
[recipe]
id          = "engineering"
description = "Standard engineering squad."

# Default roster applied by `aon team-new engineering <team-name>`.
# Operator name comes from $USER (or --operator).
[[roles]]
recipe = "eng-manager"
name   = "@OPERATOR@"

[[roles]]
recipe = "backend-engineer"
# name supplied at onboard time

[[roles]]
recipe = "backend-engineer"

[[roles]]
recipe = "frontend-engineer"

[[roles]]
recipe = "sre"
```

### New commands

| Command | Behavior |
|---|---|
| `aon recipe list [--kind roles\|teams]` | List available recipe ids (with one-line description). |
| `aon recipe show <id>` | Cat the recipe TOML. |
| `aon team-new <team-recipe> [team-name]` | `aon init` in cwd, applies team recipe to seed the roster (manager seeded, others left as named placeholders). |
| `aon add-role <name> --recipe <role>` | Append role to roster, pulling kind/domain/learning from recipe instead of CLI args. |
| `aon onboard <name> <bits> --recipe <role>` | Same, in one shot with token emission. |

### Behavior notes

- `aon onboard NAME BITS KIND DOMAIN` (no `--recipe`) keeps working — recipes are additive.
- Recipes resolve at apply time. Updating a recipe in the engine does NOT retroactively edit a team's `aon.toml`. (Avoids surprise drift.)
- `aon recipe show` prints the resolved fragment + the auth/prompt templates it points at, so operators can audit before applying.
- Team recipes can reference `@OPERATOR@` and `@TEAM_NAME@` placeholders the same way `aon.toml.example` does.

### Files to edit

- `templates/recipes/roles/*.toml` — new (start with the 9 listed above; ship more in follow-ups).
- `templates/recipes/teams/*.toml` — new (engineering first; sales + research as stretch).
- `bin/aon` — `cmd_recipe`, `cmd_team_new`, `--recipe` flag in `cmd_add_role` + `cmd_onboard`.
- `bin/_aon-lib.sh` — `_aon_recipe_path`, `_aon_load_role_recipe`, `_aon_load_team_recipe`, `_aon_apply_role_recipe` helpers.
- `templates/aon.toml.example` — unchanged; remains the bare-bones default for `aon init` without a recipe.

## Verification

1. `aon recipe list` → shows roles + teams from `templates/recipes/`.
2. `aon recipe show backend-engineer` → cats the TOML fragment.
3. `mkdir /tmp/foo && cd /tmp/foo && aon team-new engineering foo` →
   - writes `aon.toml` with team.name=foo
   - roster has eng-manager (operator=$USER), 2x backend-engineer (no name yet), 1x frontend-engineer, 1x sre
4. `aon add-role alice --recipe backend-engineer` → appends `[[roles]]` with name=alice, kind=specialist, domain=python, learning=go.
5. `aon onboard bob <bits> --recipe sre` → adds + onboards bob with kind=specialist, domain=terraform, learning=python.
6. `aon recipe show <unknown>` → clear error, lists known recipes.
7. Existing call sites (`aon onboard alice <bits> generalist python`) still work — recipes are opt-in.

## Out of scope (separate cards)

- GUI / picker for recipe selection.
- Recipe versioning / dependency on engine SHA.
- Customer-specific recipes shipped outside engine repo (e.g. via a shared registry).
- Auto-suggesting a team recipe based on cwd / git remote heuristics.
