#!/usr/bin/env bash
# Unit tests for classifier confidence field extraction and deny message formatting.
# No live ollama required — stubs classifier-ollama.sh with a fake that returns
# controlled JSON. Copies the security scripts dir to a tempdir and swaps the
# classifier so cmd-gate.sh picks up the stub via its own $HERE resolution.
#
# Run:  bash scripts/hooks/tests/test-cmd-gate-confidence.sh
set -u

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SECURITY_DIR="$ENGINE_DIR/scripts/security"
[ -x "$SECURITY_DIR/cmd-gate.sh" ] || { echo "missing cmd-gate.sh"; exit 1; }

WORKDIR="$(mktemp -d -t aon-gate-conf.XXXXXX)"
export AON_GATE_LOCAL_DIR="$WORKDIR/local"
export AON_GATE_CACHE_DIR="$WORKDIR/cache"
export AON_GATE_LOG="$WORKDIR/gate.log"
export AON_GATE_TIMEOUT_MS="500"
export AON_GATE_FALLBACK="deny"
export AON_GATE_BYPASS="0"
mkdir -p "$AON_GATE_LOCAL_DIR" "$AON_GATE_CACHE_DIR"
unset AON_NATS_URL AON_CREDS

# Stubbed security dir: full copy with classifier-ollama.sh replaced by a
# configurable fake. AON_STUB_VERDICT / AON_STUB_CONFIDENCE / AON_STUB_REASON
# control what the stub emits.
STUB_DIR="$WORKDIR/security"
cp -r "$SECURITY_DIR/." "$STUB_DIR/"
cat >"$STUB_DIR/classifier-ollama.sh" <<'STUB'
#!/usr/bin/env bash
read -r _ || true   # consume stdin (argv)
verdict="${AON_STUB_VERDICT:-deny}"
conf="${AON_STUB_CONFIDENCE:-0.9}"
reason="${AON_STUB_REASON:-stub reason}"
if [ "$conf" = "null" ]; then
  jq -nc --arg v "$verdict" --arg r "$reason" \
    '{verdict:$v,category:"stub",reason:$r,confidence:null}'
else
  jq -nc --arg v "$verdict" --argjson c "$conf" --arg r "$reason" \
    '{verdict:$v,category:"stub",reason:$r,confidence:$c}'
fi
STUB
chmod +x "$STUB_DIR/classifier-ollama.sh"

STUB_GATE="$STUB_DIR/cmd-gate.sh"

PASS=0; FAIL=0; total=0

report() {
  local name="$1" want_rc="$2" got_rc="$3" want_re="${4:-}" out="$5"
  total=$((total+1))
  local fail=0
  [ "$want_rc" != "$got_rc" ] && fail=1
  if [ -n "$want_re" ]; then
    printf '%s' "$out" | grep -E -q -- "$want_re" || fail=1
  fi
  if [ "$fail" -eq 0 ]; then
    PASS=$((PASS+1)); printf '  ok  %s\n' "$name"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$name"
    printf '       want rc=%s got=%s\n' "$want_rc" "$got_rc"
    [ -n "$want_re" ] && printf '       want output~/%s/\n' "$want_re"
    printf '       output: %s\n' "$out"
  fi
}

run_gate() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$input" | bash "$STUB_GATE" 2>&1
  return $?
}

# ── stub sanity ────────────────────────────────────────────────────────────────
echo "── stub sanity ──"
# Use export so vars propagate through the pipe into the classifier subprocess.
export AON_STUB_VERDICT=deny AON_STUB_CONFIDENCE=0.95 AON_STUB_REASON="data destruction"
out=$(printf 'some cmd\n' | bash "$STUB_DIR/classifier-ollama.sh")
conf=$(printf '%s' "$out" | jq -r '.confidence')
report "stub emits confidence=0.95" 0 0 '' ""
[ "$conf" = "0.95" ] || { PASS=$((PASS-1)); FAIL=$((FAIL+1))
  printf '  FAIL want 0.95 got %s\n' "$conf"; }

export AON_STUB_VERDICT=deny AON_STUB_CONFIDENCE=null AON_STUB_REASON="error"
out=$(printf 'some cmd\n' | bash "$STUB_DIR/classifier-ollama.sh")
conf=$(printf '%s' "$out" | jq -r '.confidence')
report "stub emits confidence=null" 0 0 '' ""
[ "$conf" = "null" ] || { PASS=$((PASS-1)); FAIL=$((FAIL+1))
  printf '  FAIL want null got %s\n' "$conf"; }

# ── confidence in deny message ─────────────────────────────────────────────────
echo "── gate deny message includes confidence ──"

export AON_STUB_VERDICT=deny AON_STUB_CONFIDENCE=0.92 AON_STUB_REASON="data destruction"
out=$(run_gate "some cmd not caught by regex")
rc=$?
report "deny msg contains confidence=0.92" 2 $rc 'confidence=0\.92' "$out"

export AON_STUB_VERDICT=deny AON_STUB_CONFIDENCE=0.6 AON_STUB_REASON="maybe destructive"
out=$(run_gate "some cmd not caught by regex")
rc=$?
report "deny msg contains confidence=0.6" 2 $rc 'confidence=0\.6' "$out"

# ── null confidence prints as "null" not "?" ───────────────────────────────────
echo "── null confidence renders as null, not ? ──"

export AON_STUB_VERDICT=deny AON_STUB_CONFIDENCE=null AON_STUB_REASON="classifier error"
out=$(run_gate "some cmd not caught by regex")
rc=$?
report "deny msg: confidence=null (not ?)" 2 $rc 'confidence=null' "$out"
printf '%s' "$out" | grep -qF 'confidence=?' && {
  PASS=$((PASS-1)); FAIL=$((FAIL+1))
  printf '  FAIL output contains confidence=? — should be null\n'; } || true

# ── ask path: confidence in audit/ask_reason ──────────────────────────────────
echo "── ask path includes confidence ──"

export AON_STUB_VERDICT=ask AON_STUB_CONFIDENCE=0.5 AON_STUB_REASON="ambiguous"
out=$(run_gate "some cmd not caught by regex")
rc=$?
# operator-ask fails (no NATS_URL) → fallback=deny; message should carry confidence
report "ask fallback deny contains confidence=0.5" 2 $rc 'confidence=0\.5' "$out"

# ── allow path: passes through cleanly ────────────────────────────────────────
echo "── allow path unaffected ──"

export AON_STUB_VERDICT=allow AON_STUB_CONFIDENCE=0.99 AON_STUB_REASON="read-only"
out=$(run_gate "some cmd not caught by regex")
rc=$?
report "allow verdict → exit 0" 0 $rc '' "$out"

echo
echo "── results ──"
echo "  $PASS passed, $FAIL failed (of $total)"
rm -rf "$WORKDIR"
exit "$FAIL"
