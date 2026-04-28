#!/usr/bin/env bash
# Pin `aon revoke clear` surface: non-revoked, revoked, and unknown-role cases.
#
# Card: aon-revoke-clear-friendly-error.

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AON="$HERE/../../bin/aon"
[[ -x "$AON" ]] || { echo "✗ no aon at $AON" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fixture team dir with aon.toml.
TEAM="$WORK/team-aon"
mkdir -p "$TEAM"
cat > "$TEAM/aon.toml" <<'TOML'
[engine]
version = "0.1"
[team]
name = "fixture-team"
account = "fixture-account"
kv = "fixture-kv"
[nats]
url = "nats://fixture.local:4222"
[paths]
task_dir = ".tasks"
prompts_dir = "agent-prompts"
agents_dir = "agents"
hooks_dir = "hooks"
TOML

# Stub nsc — behaviour controlled by env vars:
#   NSC_USER_EXISTS   = 1 (default) | 0
#   NSC_REVOKED       = 1 | 0 (default)
#   NSC_DELETE_MARKER = path to a file touched when delete-user is called
NSC_BIN="$WORK/bin/nsc"
mkdir -p "$WORK/bin"
cat > "$NSC_BIN" <<'SH'
#!/usr/bin/env bash
# Stub nsc — behaviour controlled by env vars:
#   NSC_USER_EXISTS   = 1 (default) | 0
#   NSC_REVOKED       = 1 | 0 (default); 0 → delete-user emits "no user revocations"
#   NSC_DELETE_MARKER = path to a file touched when delete-user succeeds
case "$*" in
  "describe user"*)
    [[ "${NSC_USER_EXISTS:-1}" == "1" ]] || exit 1
    exit 0
    ;;
  "revocations delete-user"*)
    if [[ "${NSC_REVOKED:-0}" != "1" ]]; then
      printf 'no user revocations set in account fixture-account\n' >&2
      exit 1
    fi
    [[ -n "${NSC_DELETE_MARKER:-}" ]] && touch "$NSC_DELETE_MARKER"
    exit 0
    ;;
  "describe account"*"--field sub"*)
    printf 'FAKE_TEAM_ID'
    exit 0
    ;;
  "describe account"*"--raw"*)
    printf 'fake.jwt.token'
    exit 0
    ;;
  "push"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$NSC_BIN"

run() {
  unset AON_NATS_URL AON_NATS_WS_URL AON_NATS_ADMIN
  PATH="$WORK/bin:$PATH" AON_TEAM_DIR="$TEAM" "$AON" "$@"
}

# Case 1: non-revoked role → exit 0, warns "not revoked", delete-user NOT called.
DELETE_MARKER="$WORK/delete-called"
out="$(NSC_USER_EXISTS=1 NSC_REVOKED=0 NSC_DELETE_MARKER="$DELETE_MARKER" \
  PATH="$WORK/bin:$PATH" AON_TEAM_DIR="$TEAM" "$AON" revoke clear fixture-role 2>&1)"; rc=$?
[[ $rc -eq 0 ]] \
  || fail "case 1: non-revoked expected rc=0, got $rc; output: $out"
grep -q "not revoked" <<<"$out" \
  || fail "case 1: missing 'not revoked' warning; got: $out"
[[ ! -f "$DELETE_MARKER" ]] \
  || fail "case 1: delete-user was called on non-revoked role"
ok "non-revoked role → rc=0, warns 'not revoked', delete-user skipped"

# Case 2: revoked role → exit 0, ok message, delete-user WAS called.
DELETE_MARKER2="$WORK/delete-called-2"
out="$(NSC_USER_EXISTS=1 NSC_REVOKED=1 NSC_DELETE_MARKER="$DELETE_MARKER2" \
  PATH="$WORK/bin:$PATH" AON_TEAM_DIR="$TEAM" "$AON" revoke clear fixture-role 2>&1)"; rc=$?
[[ $rc -eq 0 ]] \
  || fail "case 2: revoked expected rc=0, got $rc; output: $out"
grep -q "cleared revocation" <<<"$out" \
  || fail "case 2: missing 'cleared revocation' message; got: $out"
[[ -f "$DELETE_MARKER2" ]] \
  || fail "case 2: delete-user was NOT called for revoked role"
ok "revoked role → rc=0, 'cleared revocation', delete-user called"

# Case 3: unknown role → rc!=0, error has 'fix:' directive, no raw nsc error.
out="$(NSC_USER_EXISTS=0 NSC_REVOKED=0 \
  PATH="$WORK/bin:$PATH" AON_TEAM_DIR="$TEAM" "$AON" revoke clear ghost-role 2>&1)"; rc=$?
[[ $rc -ne 0 ]] \
  || fail "case 3: unknown role expected non-zero rc, got 0"
grep -q "fix:" <<<"$out" \
  || fail "case 3: missing 'fix:' directive; got: $out"
grep -q "ghost-role" <<<"$out" \
  || fail "case 3: role name not in error message; got: $out"
ok "unknown role → rc!=0, 'fix:' directive surfaced"

ok "ALL OK"
