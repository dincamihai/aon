---
column: Done
priority: high
created: 2026-04-29
owner: rona
---

# PR #57 e2e results — stale cursor deletion (F5)

Branch: `tim/fix-stale-cursor-deletion-f5` commit `005c075`

## Results (round 1)

| Case | Result | Notes |
|------|--------|-------|
| 1 multi-role host: starting rona does not touch peer cursors | PASS | sun, tim, joana cursors all preserved |
| 2 off-roster role cursor is cleaned up | PASS | ghost, oldbot cursors pruned; rona cursor kept |
| 3 single-role host behavior unchanged | PASS | own cursor preserved |
| 4 regression: session-start catch-up works, no inbox flood, no duplicate side-effects | PASS | 50 events replayed, peer sun cursor intact after rona session-start |

## Fix verified

`_hook_roster_from_toml()` parses `[[roles]]` sections from `aon.toml`. Prune loop now:
- Skips own role (`HOOK_ROLE`)
- Skips any role that appears in the roster
- Deletes only cursor files for roles absent from roster

Old behavior: deleted all non-own cursor files unconditionally.

## Verdict

**Ready to merge.** All 4 cases pass. No regression.
