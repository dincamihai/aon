---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 235
priority: high
parent: team-alpha-team-portability
depends_on: team-alpha-meta-aon-cli
---

> **Status (2026-04-27, slice 3 shipped):** seven templates ship at
> `templates/auth/{header,sysadmin,manager,generalist,specialist,sys,footer}.tmpl`.
>
> - `aon auth render` walks roster, picks per-kind ACL block,
>   substitutes `@ROLE@`, `@ROLE_TITLE@`, `@ROLE_UPPER@`,
>   `@DOMAIN@`, `@LEARNING@`, `@KV_BUCKET@`, `@TEAM_ACCOUNT@`.
>   Concatenates header + sysadmin + per-role + sys + footer to
>   `nats/auth.conf.example`.
> - `aon auth set-passwords` finds all `PASSWORD_<NAME>` placeholders,
>   generates `openssl rand -hex 24` per name, writes
>   `nats/auth.conf` + `nats/.passwords` mapping (chmod 600).
>
> Smoke green: empty dir → `aon init` (default 6-role roster) →
> `aon auth render` produces auth.conf.example with 8 unique
> placeholders → `aon auth set-passwords` substitutes all 8 → only
> the leading comment line still mentions `PASSWORD_*`. Mihai
> (manager), Raj (generalist), Priya (specialist terraform/python)
> blocks all render with correct ACL shape per kind.
>
> Multi-domain specialists (e.g. priya{terraform,aws}) deferred —
> aon.toml schema today has single `domain` field. Operators can
> hand-edit the rendered output for now; multi-domain support is
> a follow-up refinement.

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
