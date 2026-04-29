---
column: Backlog
priority: low
created: 2026-04-29
source: rona observation on PR #52 (commit 0f0c653)
parent: aon-prompts-render-non-destructive.md
---

# `aon prompts show` include resolver — add explicit absolute-path rejection

PR #52 closed the path-traversal vector via `_aon_realpath` + prefix-check against `$AON_ENGINE_DIR/templates/`. Verified end-to-end (rona 5/5 PASS).

Defense-in-depth opportunity rona flagged: an absolute path like `/etc/passwd` is blocked **implicitly** today — `$AON_ENGINE_DIR/templates/$inc_raw` becomes `<engine>/templates//etc/passwd`, which `_aon_realpath` resolves and the prefix check rejects. Works, but the rejection comes from a string-concat side effect, not explicit intent. If a future refactor changes how `$inc_raw` is joined, the implicit guard quietly disappears.

## Fix

Add an explicit reject for absolute paths at the top of the include parser, before the realpath dance:

```bash
case "$inc_raw" in
  /*)
    aon_warn "AON-INCLUDE: absolute paths not allowed: $inc_raw"
    return 1
    ;;
esac
```

Same for `~`-prefixed paths if those slip through shell expansion.

## Acceptance

1. `<!-- AON-INCLUDE: /etc/passwd -->` is rejected with a clear absolute-path-not-allowed message, not via the prefix check.
2. `<!-- AON-INCLUDE: ../../../etc/passwd -->` still rejected via existing realpath + prefix check.
3. `<!-- AON-INCLUDE: role-brief.md -->` still expands cleanly.
4. Test in `scripts/aon-tests/` covers all three.

## Why low

The implicit rejection is correct today and PR #52 covers the immediate threat. This is hardening for code-evolution resilience.
