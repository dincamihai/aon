---
column: In Progress
created: 2026-04-28
priority: medium
parent: aon-require-team-git-rejects-worktrees
follow_up_of: PR#35
---

# Run all `scripts/aon-tests/*.sh` in CI

PR #35 introduced `scripts/aon-tests/git-guard.sh` and blessed
`scripts/aon-tests/` as the canonical home for engine unit-style
tests (separate from `scripts/nsc-smoke/`, the NSC pipeline e2e).
PR #35 wired `git-guard.sh` as a per-test step in CI. This card
generalizes that wire-in: any new file under `scripts/aon-tests/*.sh`
runs automatically without a CI edit.

## Scope

1. Add a step to `.github/workflows/nsc-smoke.yml` that iterates
   `scripts/aon-tests/*.sh` and executes each. Fail the job on any
   non-zero exit.
2. Each test script handles its own setup/teardown and prints a
   clear PASS/FAIL summary line per case.
3. Tests must be idempotent and self-contained; order-independent.

## Acceptance

1. Adding a new `scripts/aon-tests/foo.sh` with `chmod +x` makes it
   run on next CI without any `.github/workflows/*.yml` edit.
2. A failing test in any `aon-tests/*.sh` fails the CI job with
   that script's name surfaced in the GitHub Actions summary.
3. Local invocation `bash scripts/aon-tests/_run-all.sh` reproduces
   the CI flow end-to-end with the same exit semantics.
4. Existing `scripts/aon-tests/git-guard.sh` runs under the new
   runner with no source change.
5. README updated with one-paragraph note pointing future tests at
   `scripts/aon-tests/`.
6. `scripts/nsc-smoke/run-smoke.sh` unchanged — the two suites stay
   separate.

## Out of scope

- Migrating any existing test from nsc-smoke to aon-tests.
- Parallelism (sequential v1; revisit if total runtime > 2min).
- Coverage reporting / TUI test discovery.

## Gate

- `_run-all.sh` exits 0 on clean tree.
- CI job green on this PR.
