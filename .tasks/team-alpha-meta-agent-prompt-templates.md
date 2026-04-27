---
column: Backlog
created: 2026-04-27
order: 234
priority: high
parent: team-alpha-team-portability
depends_on: team-alpha-meta-aon-cli
---

# Card 234 — Meta: templatize agent prompts (`role.md.tmpl`)

`scripts/agent-prompts/<role>.md` today bake the team-alpha role names,
domains, and NATS subject taxonomy directly into the markdown. A
new team can't reuse them without sed-replacing the whole tree.

Convert each prompt to a template under `templates/agent-prompts/`:

```
templates/agent-prompts/
  _common.md.tmpl
  manager.md.tmpl
  generalist.md.tmpl
  specialist.md.tmpl
```

Templates use `@VAR@` placeholders — same convention used in Card
229's plist (`@WATCHER@`, `@REPOS_ROOT@`). Renderer is a small
sed pipeline; no Jinja, no Python dep.

## Variables

| Variable | Source |
|---|---|
| `@ROLE@` | role name from `aon.toml` roster |
| `@ROLE_TITLE@` | Title-Cased name |
| `@ROLE_KIND@` | `manager` / `generalist` / `specialist` |
| `@DOMAIN@` | primary domain (terraform, python, ui, …) |
| `@LEARNING@` | growth domain (optional) |
| `@TEAM_NAME@` | from aon.toml |
| `@PROJECT_NAME@` | from aon.toml |
| `@KV_BUCKET@` | derived: `<team>-state` |
| `@SUBJECT_PREFIX@` | derived: `org.<team>.>` (Card 235) |

## Deliverables

- `templates/agent-prompts/{_common,manager,generalist,specialist}.md.tmpl`
  carved from the existing `scripts/agent-prompts/*.md` content.
- `_render_template` helper in `bin/_aon-lib.sh` (Card 233).
- `aon init` + `aon add-role` invoke the renderer.
- Existing `scripts/agent-prompts/<role>.md` files: regenerate via
  the renderer to confirm round-trip parity.

## Acceptance

- Re-rendering team-alpha's existing 6 roles from templates produces
  output diff-equivalent to the hand-written files (modulo whitespace).
- `aon add-role neeraj specialist --domain rust` produces a prompt
  that references rust subjects + scope correctly.

## Non-goals

- Not Jinja, not Mustache. Sed `@VAR@` substitution. If a feature
  needs conditionals (`{% if … %}`), defer.
