---
column: Backlog
priority: low
created: 2026-04-29
---

# aon auth render should backup + restore tokens automatically

`aon auth render` re-issues operator/account JWTs on every run. If the JWT changes, running NATS servers keep stale claims until restart. `aon creds --all` can produce different creds.

Tool should:

1. Snapshot current `~/.aon/teams/<team>/nats/resolver/` + `~/.aon/teams/<team>/creds/*.creds` before rendering
2. Compare old vs new after render
3. If creds differ, offer to restore or print diff
4. If JWT changed, warn about stale claims until restart

## Acceptance

1. `aon auth render --backup` creates timestamped backup before changes.
2. After render, prints summary of what changed (creds diff, JWT rotation).
3. `aon auth render --restore <backup-dir>` restores previous state.
4. No flag = dry-run with warning if JWTs would rotate.

## Out of scope

- Automatic rollback on error (too complex for v1).
- Integration with `aon nats reload`.
