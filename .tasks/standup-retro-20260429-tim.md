# Standup + Retro — tim — 2026-04-29

## Standup

### Shipped
- **PR #57** (F5): fix stale cursor deletion wiping peer cursors on multi-role host. Replaced wipe-all loop with roster-aware prune via `_hook_roster_from_toml()` (POSIX awk, BSD-safe). Regression test 4/4 PASS. Merged.
- **PR #58 review** (F2 + ACL drift): verified `explicit_role:-_first_role` one-liner correct; `_aon_nsc_acl_sig` / `_aon_nsc_jwt_acl_sig` sha256 helpers match `_aon_nsc_ensure_user` exactly; `--apply-acl-drift` opt-in + graceful failure. Ready-for-final. 6/6 e2e PASS. Merged.
- **PR #59 review** (resolve-env KV fallback): guard `kv==team-state` correct; toml fallback more defensive than `aon_load_config` (applies name fallback even with toml present, no kv_bucket) — improvement not regression. Ready-for-final. 4/4 e2e PASS. Merged.
- **Stale card closures**: verified Bug2+D2+D1+F3 all already fixed in main (PRs #47, #48). Closed 4 cards without writing unnecessary PRs.

### Blocked
None.

---

## Retro

### What went well
1. **Stale card detection was fast.** Checked live code before writing any fix — saved 4 unnecessary PRs. Habit of `grep` before branching paid off.
2. **BSD awk `\s` regression caught by test before PR.** Test showed `FAIL: peer cursor WIPED` immediately; traced to macOS awk not supporting `\s`. Fixed to `[[:space:]]` before pushing. Test-first paid off.
3. **Review pipeline smooth.** dispatch → review → rona e2e → merge with no long waits. Single-round review on #57, #59. PR #55 needed 4 rounds but each fix was targeted.

### What could be better
1. **Card staleness is a recurring pattern.** Cards written against old commits get dispatched after the bug is already fixed. A card-age/commit-range check at dispatch time (e.g. "this card references commit `3bb3312` — is it still relevant on main?") would surface staleness before work is assigned.
2. **Two sources of truth for ACL strings.** `_aon_nsc_acl_sig` and `_aon_nsc_ensure_user` now duplicate the allow/deny/sub subject strings. Any future ACL change must be applied in both places or drift detection produces false positives. Worth a comment block or a single source (e.g. per-kind ACL arrays) to keep them in sync.
