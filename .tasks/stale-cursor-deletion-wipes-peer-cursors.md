---
column: Done
priority: medium
created: 2026-04-29
source: joana audit (F5) on 4d5911b..62dc26d
---

# Stale-cursor deletion wipes peer cursors on multi-role hosts

Commit `d5aa68f` (`fix(aon): role detection in hooks + monitor`).

`scripts/hooks/_lib.sh:20-28` — loop deletes `last-seen-<role>` for every role that doesn't match `HOOK_ROLE` in the team cursor dir.

On a multi-role host (e.g. joana + rona + tim sharing `~/.aon/teams/workers/cursors/`), starting joana's hook destroys rona's and tim's cursors. Each peer then re-replays everything from the beginning of their stream on next start, flooding the inbox + duplicating side-effects of any auto-handlers.

## Fix

Only delete cursors that are clearly stale (e.g. role no longer in roster, file older than N days). Never delete cursors of currently-rostered peer roles.

## Acceptance

1. On multi-role host, starting hook for role X does not touch cursors for other rostered roles.
2. Cursors for roles no longer in `aon.toml` may be cleaned up (separate code path or explicit `--prune`).
3. Add regression test simulating two roles in same team dir.

## Why medium

Single-role hosts unaffected, but our reference setup runs multiple roles per host (workers team is exactly this). Each unrelated session-start currently corrupts peer state.
