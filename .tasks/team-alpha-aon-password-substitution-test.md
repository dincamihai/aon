---
column: Backlog
created: 2026-04-27
order: 248
priority: medium
parent: team-alpha-meta-auth-conf-templates
---

# Card 248 — Regression test for `aon auth set-passwords` prefix collision

PR #10 fixed a prefix-collision bug: `PASSWORD_SYS` matched as
prefix of `PASSWORD_SYSADMIN` when sed-substituting in
encounter order, leaving `<sys-pw>ADMIN` as the sysadmin
password in the rendered auth.conf.

Fix: sort placeholders by length descending before sed.

## Goal

Add a regression test so the bug can't regress silently.

## Deliverables

- `tests/aon/auth-set-passwords.bats` (or shell script) that:
  1. Builds a synthetic `nats/auth.conf.example` with
     `PASSWORD_SYS`, `PASSWORD_SYSADMIN`, and another
     prefix-share example (e.g. `PASSWORD_FOO` +
     `PASSWORD_FOOBAR`).
  2. Runs `aon auth set-passwords`.
  3. Asserts every placeholder substituted to a 48-hex value
     with no residual letters from other placeholders.
  4. Asserts each user's substituted secret is unique.
- Wire into existing smoke harness (`scripts/smoke/`).

## Acceptance

- Test passes on current main (post-PR #10).
- Reverting the fix in `bin/aon` makes the test fail.

## Why

Prevent the same class of bug. Cheap insurance.
