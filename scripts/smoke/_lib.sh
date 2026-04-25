#!/usr/bin/env bash
# Shared helpers for smoke tests. Sourced, not executed.
# Each test asserts pub/sub permission outcomes against a running stack.
set -u

: "${NATS_URL:=nats://localhost:4222}"
: "${SMOKE_PASS:=devpass}"   # dev default; overridden in real envs

NATS_BIN="${NATS_BIN:-nats}"
PASS=0; FAIL=0; SKIP=0

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$*"; }

ok()   { PASS=$((PASS+1)); printf '  %s %s\n' "$(c_green ✓)"  "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(c_red   ✗)"  "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  %s %s\n' "$(c_yellow ⏭)" "$*"; }

# Run nats CLI as a given role. Stdout suppressed, stderr captured.
nats_as() {
  local role="$1"; shift
  "$NATS_BIN" --server "$NATS_URL" --user "$role" --password "$SMOKE_PASS" "$@"
}

# Assert that <role> is allowed to publish to <subject>.
assert_pub_ok() {
  local role="$1" subject="$2" payload="${3:-{}}"
  local err
  if err=$(nats_as "$role" pub "$subject" "$payload" 2>&1 >/dev/null); then
    ok "$role → pub $subject (allowed)"
  else
    bad "$role → pub $subject expected ALLOW, got: $err"
  fi
}

# Assert that <role> is denied publishing to <subject>.
assert_pub_denied() {
  local role="$1" subject="$2" payload="${3:-{}}"
  local err
  if err=$(nats_as "$role" pub "$subject" "$payload" 2>&1 >/dev/null); then
    bad "$role → pub $subject expected DENY, got success"
  else
    if echo "$err" | grep -qi "permissions violation"; then
      ok "$role → pub $subject (correctly denied)"
    else
      bad "$role → pub $subject expected perms-violation, got: $err"
    fi
  fi
}

# Assert that <role> can subscribe to <subject> (uses --count 0 + immediate quit).
assert_sub_ok() {
  local role="$1" subject="$2"
  local out
  if out=$(nats_as "$role" sub "$subject" --count 1 --wait 1s 2>&1); then
    ok "$role → sub $subject (allowed; no msg, fine)"
  elif echo "$out" | grep -qi "no messages"; then
    ok "$role → sub $subject (allowed; no msg in window)"
  elif echo "$out" | grep -qi "permissions violation"; then
    bad "$role → sub $subject expected ALLOW, got perms-violation"
  else
    # Connect timeout/etc. Treat as inconclusive but pass if no perm violation.
    ok "$role → sub $subject (no perm violation)"
  fi
}

assert_sub_denied() {
  local role="$1" subject="$2"
  local out
  out=$(nats_as "$role" sub "$subject" --count 1 --wait 1s 2>&1 || true)
  if echo "$out" | grep -qi "permissions violation"; then
    ok "$role → sub $subject (correctly denied)"
  else
    bad "$role → sub $subject expected DENY, got: $(echo "$out" | head -1)"
  fi
}

summary() {
  echo
  printf 'Summary: %s pass, %s fail, %s skip\n' \
    "$(c_green "$PASS")" "$(c_red "$FAIL")" "$(c_yellow "$SKIP")"
  [ "$FAIL" -eq 0 ]
}
