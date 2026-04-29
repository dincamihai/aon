---
column: Done
created: 2026-04-28
priority: high
parent: aon-onboard-walks-up-to-home-git
follow_up_of: PR#33 (auto-init made this more reachable)
discovered_by: rona (exploratory)
severity: med
---

# `cmd_onboard` step 7/8 silently masks git push failure

## Bug

`bin/aon` L1724 detects push failure with:

```bash
git push 2>&1 | tail -1 | grep -qiE "rejected|error"
```

Three failure modes:

1. `tail -1` only reads the last stderr line. `fatal: No configured
   push destination` is several lines back; the last line is blank
   or `See 'git push --help'`.
2. The `rejected|error` alternation misses `fatal:` entirely.
3. The pipe loses the actual git exit code (128 here).

Result: aon prints `✓ pushed onboarding commit` while `git push`
hard-failed. Step 8/8's share-block token references unpushed state
— operators believe the team is shared when it isn't.

PR #33 auto-init made this the default first-onboard state (fresh
`aon init` creates a repo with no remote), so the bug is on the
happy path.

## Repro

```bash
mkdir /tmp/rona-explore-push && cd /tmp/rona-explore-push
git init -q -b main
echo a > a
git -c user.email=t@t -c user.name=t commit -qam x --allow-empty
git push 2>&1 | tail -1 | grep -qiE "rejected|error"; echo "matched=$?"
# matched=1  ← grep miss; aon's if-branch is NOT taken
```

## Fix

Capture exit status directly. No pipe:

```bash
local out rc
out="$(git -C "$AON_TEAM_DIR" push 2>&1)"
rc=$?
if (( rc != 0 )); then
  aon_warn "git push failed (exit $rc):"
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  # Decide: hard-fail or warn-and-continue. Recommend hard-fail
  # because step 8/8 emits a share-token that depends on push state.
fi
```

Drop fragile string matching. Surface real stderr to operator.

## Acceptance

1. `aon onboard` from a repo with **no remote** hard-fails (or
   loud-warns + skips step 8/8 token emission) instead of silently
   reporting success.
2. `aon onboard` from a repo with a **broken remote** (auth error,
   wrong URL) surfaces `git push` exit code + real stderr.
3. `aon onboard` from a repo with a **healthy remote** succeeds
   silently as today (no behavioral regression).
4. `aon onboard` from a **rejected** push (non-FF, hook reject) also
   triggers the failure path.
5. Regression test in `scripts/aon-tests/onboard-push.sh` covering
   all four cases above. Must run under the new
   `aon-tests-ci-runner.md` once that lands; runs standalone today.
6. Step 8/8 share-token emission is gated on step 7/8 success
   (don't emit a token for a push that didn't land).
7. `scripts/nsc-smoke/run-smoke.sh` Phase C green.

## Out of scope

- Auto-creating GitHub remote (operator's choice, per parent card).
- Retrying transient push failures.
- Pre-push validation (lefthook / pre-push hook integration).

## Decision needed

Hard-fail vs warn-and-skip-step-8/8? Recommend **hard-fail**:
share-token without a pushed remote is a footgun. Operators rerun
after fixing remote. Defer to mid if disagreement.

## Gate

`scripts/nsc-smoke/run-smoke.sh` Phase C +
`scripts/aon-tests/onboard-push.sh` (new).
