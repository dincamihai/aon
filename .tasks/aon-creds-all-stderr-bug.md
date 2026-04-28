---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 49
priority: high
parent: nsc-jwt-migration
---

# `aon creds --all` fails on nsc 2.12+ (stderr vs stdout)

**Shipped** in this card's commit. `cmd_creds_all` parsed stdout
of `nsc list users --account <team> --json`. nsc 2.12.x writes
that output to **stderr** instead. Result: parser gets empty
input → "no NSC users in account 'X' — run 'aon auth render'
first" right after a successful render that just created users.

## Repro (before fix)

```
$ cd ~/Repos/workers
$ aon auth render
✓ users: created=3 existed=0 (sysadmin always ensured)
$ aon creds --all
✗ no NSC users in account 'workers' — run 'aon auth render' first
```

Same failure on the table-output fallback (also stderr).

## Fix

Merge stderr into stdout (`2>&1`) on both the `--json` and the
table fallback in `bin/aon` `cmd_creds_all`. Comment notes that
older nsc wrote to stdout — once merged, both paths work.

## Acceptance

- `aon creds --all` after `aon auth render` emits one `.creds`
  per NSC user (verified on workers team: joana, mid, sysadmin,
  tim).
- Same flow continues to work if nsc reverts to stdout in a
  future release (merge is harmless).

## Out of scope

- Pinning nsc version (covered by CI workflow `nsc-smoke.yml`
  pinning 2.12.2; matches local).
- Fixing other `aon` commands that may have the same bug — quick
  audit shows `cmd_creds_all` was the only stdout-parser of nsc
  list output. `cmd_revoke list` shells `nsc revocations
  list-users` for human display, no parse.

## References

- nsc 2.12.2 release behavior change.
- `bin/aon` `cmd_creds_all` (~line 960).
