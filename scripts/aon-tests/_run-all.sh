#!/usr/bin/env bash
# Run every `scripts/aon-tests/*.sh` (except this runner) sequentially.
# Each script is self-contained; failure of any one fails the runner.
# Same script is invoked from .github/workflows/nsc-smoke.yml so adding
# a new test = drop a `chmod +x` script next to this one. No CI edit.

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

# GitHub Actions group helpers — collapse output per test in the
# Actions log. Stay no-op when running locally.
gh_group_open()  { [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::group::%s\n' "$1" || true; }
gh_group_close() { [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::endgroup::\n'    || true; }
gh_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -w "$GITHUB_STEP_SUMMARY" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

shopt -s nullglob
mapfile -t TESTS < <(printf '%s\n' "$HERE"/*.sh | grep -v "/$SELF\$" | sort)
shopt -u nullglob

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "no tests under $HERE — nothing to run" >&2
  exit 0
fi

PASS=0; FAIL=0; FAILED=()
gh_summary "## aon-tests"
gh_summary ""
gh_summary "| script | status |"
gh_summary "|---|---|"

for t in "${TESTS[@]}"; do
  name="$(basename "$t")"
  printf '── %s ──\n' "$name"
  gh_group_open "$name"
  if bash "$t"; then
    PASS=$((PASS+1))
    gh_summary "| \`$name\` | ✓ pass |"
  else
    rc=$?
    FAIL=$((FAIL+1))
    FAILED+=("$name (rc=$rc)")
    gh_summary "| \`$name\` | ✗ FAIL (rc=$rc) |"
  fi
  gh_group_close
done

printf '\n══ aon-tests: pass=%d fail=%d ══\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf 'failed:\n' >&2
  for f in "${FAILED[@]}"; do printf '  - %s\n' "$f" >&2; done
  exit 1
fi
exit 0
