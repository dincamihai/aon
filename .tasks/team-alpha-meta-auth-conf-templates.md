---
column: Backlog
created: 2026-04-27
order: 235
priority: high
parent: team-alpha-team-portability
depends_on: team-alpha-meta-aon-cli
---

# Card 235 — Meta: templatize `nats/auth.conf` from roster

Today `nats/auth.conf` is hand-written: 8 user blocks, each with a
~40-line ACL. Adding a role = duplicating one of the existing blocks
and remembering to update both publish + subscribe sections.

Generate auth.conf from `aon.toml` roster + per-kind ACL templates.

## Inputs

`aon.toml`:

```toml
[team]
name        = "team-alpha"
account     = "team-alpha"
kv_bucket   = "team-state"

[[roles]]
name   = "mihai"
kind   = "manager"
domain = "manager"

[[roles]]
name   = "raj"
kind   = "generalist"
domain = "python"
learning = "go"

[[roles]]
name   = "priya"
kind   = "specialist"
domain = "terraform"
learning = "python"
```

ACL templates: `templates/auth/{sysadmin,manager,generalist,specialist}.tmpl`
+ a wrapper `templates/auth/auth.conf.tmpl`.

## Deliverables

- `templates/auth/*.tmpl` carved from existing auth.conf user blocks.
- `aon auth render` subcommand (or part of `aon init`) — emits
  `nats/auth.conf.example` from current roster, with `PASSWORD_<ROLE>`
  placeholders.
- `aon auth set-passwords` — generates random passwords, substitutes
  into the live `nats/auth.conf`, writes mapping to a gitignored
  `nats/.passwords` file.
- Existing teams: `aon auth render --check` diffs current
  auth.conf.example against rendered output (must be empty modulo
  comment).

## Acceptance

- Re-rendering team-alpha's roster produces an auth.conf.example
  diff-equivalent to the hand-written one.
- `aon add-role neeraj specialist --domain rust` updates aon.toml,
  re-renders auth.conf.example with the new block, prints the
  `PASSWORD_NEERAJ=<secret>` line for distribution.

## Non-goals

- NSC/JWT migration is a separate card (`nsc-jwt-migration.md`).
  This card stays in shared-secret territory.
