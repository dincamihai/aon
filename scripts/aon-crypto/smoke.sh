#!/usr/bin/env bash
# Round-trip + tamper smoke for scripts/aon-crypto/box.py.
# Exits non-zero on any mismatch. Pure stdin/stdout — no temp files.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BOX="$HERE/box.py"
PY="${PYTHON:-python3}"

run() { "$PY" "$BOX" "$@"; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

# --- 1. keypair shape ---
kp1="$(run keypair)"
pub1="$(jq -r .pub <<<"$kp1")"; priv1="$(jq -r .priv <<<"$kp1")"
[[ -n "$pub1" && -n "$priv1" ]] || fail "keypair missing pub/priv"
[[ "$(printf '%s' "$pub1"  | base64 -d | wc -c | tr -d ' ')" == "32" ]] || fail "pub not 32 bytes"
[[ "$(printf '%s' "$priv1" | base64 -d | wc -c | tr -d ' ')" == "32" ]] || fail "priv not 32 bytes"
ok "keypair emits 32-byte pub + priv"

# --- 2. round-trip ---
msg='hello world'
ct="$(printf '%s' "$msg" | run encrypt --pubkey "$pub1" --in -)"
pt="$(printf '%s' "$ct"  | run decrypt --privkey "$priv1" --in -)"
[[ "$pt" == "$msg" ]] || fail "round-trip mismatch: got '$pt'"
ok "round-trip preserves plaintext"

# --- 3. tampered ciphertext fails ---
tampered="$(printf '%s' "$ct" | base64 -d | python3 -c '
import sys
d = bytearray(sys.stdin.buffer.read())
d[-1] ^= 0x01
sys.stdout.buffer.write(d)
' | base64)"
if printf '%s' "$tampered" | run decrypt --privkey "$priv1" --in - >/dev/null 2>&1; then
  fail "tampered ciphertext decrypted (expected CryptoError)"
fi
ok "tampered ciphertext rejected"

# --- 4. wrong privkey fails ---
kp2="$(run keypair)"
priv2="$(jq -r .priv <<<"$kp2")"
if printf '%s' "$ct" | run decrypt --privkey "$priv2" --in - >/dev/null 2>&1; then
  fail "wrong privkey decrypted (expected CryptoError)"
fi
ok "wrong privkey rejected"

# --- 5. binary-safe round-trip (no utf-8 hazard) ---
# bash command substitution silently drops NUL bytes, so route the
# 256-byte fixture through temp files + cmp instead of shell vars.
TMPDIR_BIN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BIN"' EXIT
"$PY" -c 'import sys; sys.stdout.buffer.write(bytes(range(256)))' > "$TMPDIR_BIN/in.bin"
"$PY" "$BOX" encrypt --pubkey "$pub1" --in "$TMPDIR_BIN/in.bin" \
  | "$PY" "$BOX" decrypt --privkey "$priv1" --in - > "$TMPDIR_BIN/out.bin"
cmp -s "$TMPDIR_BIN/in.bin" "$TMPDIR_BIN/out.bin" || fail "binary round-trip mismatch"
[[ "$(wc -c <"$TMPDIR_BIN/out.bin" | tr -d ' ')" == "256" ]] || fail "binary round-trip wrong length"
ok "binary round-trip preserves all 256 bytes (incl. NUL)"

ok "ALL OK"
