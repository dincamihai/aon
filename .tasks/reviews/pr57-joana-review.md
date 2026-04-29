---
pr: 57
branch: tim/fix-stale-cursor-deletion-f5
reviewer: joana
verdict: ready-for-final
date: 2026-04-29
---

# PR #57 Review — cursor isolation on multi-role hosts (F5)

## Verdict: READY-FOR-FINAL

Rona e2e: 4/4 PASS (round 1, commit 005c075). No concerns blocking merge.

## What changed

`scripts/hooks/_lib.sh`: replaces wipe-all cursor loop with roster-aware prune.

Old code deleted ALL cursors for roles != HOOK_ROLE. On multi-role hosts (e.g. tim + joana sharing one machine), starting as `tim` wiped `joana`'s cursor → joana lost replay history on next session.

New code: only prune roles absent from the roster (`_hook_roster_from_toml`).

## _hook_roster_from_toml awk — CORRECT

```awk
/^\[\[roles/{r=1;next} /^\[/{r=0;next} r && /^[[:space:]]*name[[:space:]]*=/{
  gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); print
}
```

- `[[roles` line: first rule fires (r=1, `next`) before the `/^\[/` rule — awk processes rules left-to-right, `next` skips remaining rules for that line. ✓
- `[team]` / `[[other]]`: hits `/^\[/` → r=0. ✓
- Name extraction via double `gsub`: strips before first `"` and after last `"`. Correct for `name = "tim"` and `name="tim"`. BSD awk safe (POSIX). ✓

## Loop logic — CORRECT

```bash
[ "$_stale_role" = "$HOOK_ROLE" ] && continue  # own cursor: skip
_hook_roster_from_toml | grep -qxF "$_stale_role" || rm -f ...
```

- Own cursor: skipped ✓
- Peer in roster: `grep -qxF` succeeds → NOT deleted ✓  
- Off-roster role: `grep -qxF` fails → deleted ✓
- `-qxF`: exact-line fixed-string match — no regex injection risk ✓
- `unset _stale_cursor _stale_role`: env cleanup ✓

## HOOK_REPO_ROOT — CORRECT

Defined at `_lib.sh:9`: `${HOOK_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}`. Points to work-repo root where `aon.toml` lives. ✓

## Regression test — ADEQUATE

`test-cursor-isolation.sh`:
- AC1: own cursor preserved ✓
- AC1: peer cursor preserved ✓  
- AC2: orphan cursor pruned ✓
- Parser doesn't leak `[team].name` into roster ✓

Test reproduces exact logic from `_lib.sh` inline (no source dependency). Clean isolation. ✓

## Non-blocking notes

1. **Missing `aon.toml`**: `_hook_roster_from_toml` returns empty (early `return`). Then all non-current-role cursors get pruned (same behavior as old code, just scoped to non-self). Acceptable for F5 scope. Could be improved to preserve peers when toml unreadable, but not needed now.

2. **Empty roster** (aon.toml exists, no `[[roles]]`): same as above. All non-current cursors pruned. Same note.

3. **Test gap**: missing-toml and empty-roster cases not covered by the regression test. Non-blocking since the behavior is acceptable.
