#!/usr/bin/env bash
# scripts/nsc-smoke/run-smoke.sh
#
# S1 of `.tasks/nsc-jwt-migration.md`: prove the full NSC/JWT chain
# end-to-end against a fixture team. No engine integration here —
# this is a standalone correctness check.
#
# What it does:
#   1. Spins up a throwaway NSC home + resolver dir under a tempdir.
#   2. Initializes operator `aon-op` and account `team-aon-smoke`.
#   3. Adds 4 users mirroring the engine's auth-template kinds:
#        - sysadmin (full access)
#        - mihai    (manager)
#        - vahid    (generalist, domain=python)
#        - sara     (specialist, domain=ui, learning=go)
#   4. Permission claims translated 1:1 from templates/auth/*.tmpl,
#      with the same wildcards (@KV_BUCKET@ → team-aon-smoke-state).
#   5. Emits .creds files per user.
#   6. Boots a docker nats-server in JWT mode (operator + resolver).
#   7. For each role: connect with .creds, run allow-cases (must pass)
#      and forge-cases (must reject).
#   8. Prints PASS/FAIL summary.
#
# Requires: nsc, docker, nats CLI. No host nats-server needed.

set -euo pipefail

TEAM=team-aon-smoke
KV=${TEAM}-state
OP=aon-op

# Place the work dir under the repo so Docker Desktop's
# file-sharing config picks it up (default shares /Users; /tmp +
# /var/folders may not be shared).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="$SCRIPT_DIR/.work"
mkdir -p "$WORK_ROOT"
WORK="$(mktemp -d "$WORK_ROOT/nsc-smoke.XXXXXX")"
NSC_HOME_DIR="$WORK/nsc"
RESOLVER_DIR="$WORK/resolver"
CREDS_DIR="$WORK/creds"
SERVER_CONF="$WORK/nats-server.conf"
LOG="$WORK/nats.log"
NATS_PORT=14222
CID=

# stable container name for cleanup safety
CONTAINER="nsc-smoke-$$"

# coreutils timeout (`timeout` on linux, `gtimeout` on macOS via brew)
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
[[ -n "$TIMEOUT" ]] || { echo "need GNU timeout (brew install coreutils)" >&2; exit 1; }

cleanup() {
  set +e
  [[ -n "$CID" ]] && docker rm -f "$CID" >/dev/null 2>&1
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  if [[ "${KEEP_WORK:-0}" == "1" ]]; then
    echo "kept work dir: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

note()  { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

export XDG_DATA_HOME="$WORK/xdg-data"
export XDG_CONFIG_HOME="$WORK/xdg-config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
NSC() { nsc "$@"; }

# ── Step 1: NSC env ────────────────────────────────────────────────
note "step 1/8: init NSC home at $NSC_HOME_DIR"
mkdir -p "$NSC_HOME_DIR" "$RESOLVER_DIR" "$CREDS_DIR"

# ── Step 2: operator + account ─────────────────────────────────────
note "step 2/8: create operator '$OP' + account '$TEAM'"
NSC add operator --generate-signing-key --sys "$OP" >/dev/null
NSC edit operator --service-url "nats://127.0.0.1:$NATS_PORT" >/dev/null
NSC add account "$TEAM" >/dev/null
NSC edit account "$TEAM" --js-mem-storage 64M --js-disk-storage 256M --js-streams 32 --js-consumer 64 >/dev/null

# ── Step 3: users ─────────────────────────────────────────────────
note "step 3/8: add users (sysadmin/mihai/vahid/sara) with claim translations"

# sysadmin: full access (templates/auth/sysadmin.tmpl)
NSC add user --account "$TEAM" sysadmin \
  --allow-pubsub ">" \
  --allow-pub-response >/dev/null

# mihai: manager (templates/auth/manager.tmpl)
NSC add user --account "$TEAM" mihai \
  --allow-pub "agents.mihai.events,agents.*.inbox,broadcast.>,board.tasks.*.pending,board.tasks.review.>,a2a.*.tasks.send,a2a.*.tasks.*.cancel,a2a.discovery.>,state.project.>,\$KV.${KV}.project.>,\$KV.${KV}.team.>,\$KV.${KV}.policy.>,\$KV.${KV}.agent.mihai.>,state.>,\$JS.API.>,_INBOX.>" \
  --deny-pub "board.results.>" \
  --allow-sub ">" \
  --allow-pub-response >/dev/null

# vahid: generalist, domain=python (templates/auth/generalist.tmpl)
NSC add user --account "$TEAM" vahid \
  --allow-pub "agents.vahid.events,agents.*.inbox,broadcast.incidents,state.alert.no_human,board.tasks.*.>,board.results.>,board.learning.*.mentoring,board.learning.*.pending,a2a.vahid.tasks.>,a2a.discovery.vahid,state.agent.vahid.>,\$KV.${KV}.agent.vahid.>,\$KV.${KV}.a2a.vahid.>,\$JS.API.>" \
  --deny-pub "board.tasks.*.pending" \
  --allow-sub "agents.vahid.inbox,board.tasks.*.pending,board.learning.*.pending,board.learning.*.mentoring,a2a.vahid.tasks.send,a2a.vahid.tasks.*.cancel,a2a.vahid.tasks.>,broadcast.>,state.>,\$KV.${KV}.>,\$JS.API.>,_INBOX.>" \
  --allow-pub-response >/dev/null

# sara: specialist, domain=ui, learning=go (templates/auth/specialist.tmpl)
NSC add user --account "$TEAM" sara \
  --allow-pub "agents.sara.events,agents.*.inbox,broadcast.incidents,state.alert.no_human,board.tasks.ui.>,board.results.ui.>,board.learning.go.claimed,a2a.sara.tasks.>,a2a.discovery.sara,state.agent.sara.>,\$KV.${KV}.agent.sara.>,\$KV.${KV}.a2a.sara.>,\$JS.API.>" \
  --deny-pub "board.tasks.*.pending" \
  --allow-sub "agents.sara.inbox,board.tasks.ui.pending,board.learning.go.pending,board.learning.go.mentoring,a2a.sara.tasks.send,a2a.sara.tasks.*.cancel,a2a.sara.tasks.>,broadcast.>,state.>,\$KV.${KV}.>,\$JS.API.>,_INBOX.>" \
  --allow-pub-response >/dev/null

# ── Step 4: emit .creds ────────────────────────────────────────────
note "step 4/8: emit .creds files"
for u in sysadmin mihai vahid sara; do
  NSC generate creds --account "$TEAM" --name "$u" > "$CREDS_DIR/$u.creds"
  chmod 600 "$CREDS_DIR/$u.creds"
done
ok "creds in $CREDS_DIR"

# ── Step 5: build memory resolver config (SYS + team JWTs preloaded) ──
note "step 5/8: build memory-resolver config"
OP_JWT="$(NSC describe operator --raw 2>/dev/null | tr -d '\n')"
SYS_ID="$(NSC list accounts 2>&1 | awk '/^\| SYS /{gsub(/[ |]/,"",$0); split($0,a,"|"); print a[2]}' )"
# Robust id extraction via describe
SYS_ID="$(NSC describe account --name SYS --field sub 2>/dev/null | tr -d '"' )"
TEAM_ID="$(NSC describe account --name "$TEAM" --field sub 2>/dev/null | tr -d '"')"
SYS_JWT="$(NSC describe account --name SYS --raw 2>/dev/null | tr -d '\n')"
TEAM_JWT="$(NSC describe account --name "$TEAM" --raw 2>/dev/null | tr -d '\n')"
[[ -n "$OP_JWT" && -n "$SYS_ID" && -n "$TEAM_ID" && -n "$SYS_JWT" && -n "$TEAM_JWT" ]] \
  || { fail "missing JWT/IDs (op=${#OP_JWT} sys_id=$SYS_ID team_id=$TEAM_ID)"; exit 1; }

# ── Step 6: server conf + boot ────────────────────────────────────
note "step 6/8: write nats-server.conf + boot in docker"
cat > "$SERVER_CONF" <<EOF
port: 4222
http: 8222
jetstream: { store_dir: "/work/data" }

operator: $OP_JWT
system_account: $SYS_ID
resolver: MEMORY
resolver_preload: {
  $SYS_ID: $SYS_JWT
  $TEAM_ID: $TEAM_JWT
}
EOF

mkdir -p "$WORK/data"
CID="$(docker run -d \
  --name "$CONTAINER" \
  -p ${NATS_PORT}:4222 \
  -v "$WORK":/work \
  nats:latest \
  --config /work/nats-server.conf \
  -DV)" || { fail "docker run failed"; exit 1; }

# wait for ready
for i in $(seq 1 30); do
  if docker logs "$CONTAINER" 2>&1 | grep -q 'Server is ready'; then break; fi
  sleep 0.3
done
docker logs "$CONTAINER" > "$LOG" 2>&1 || true
grep -q 'Server is ready' "$LOG" || {
  fail "server not ready"
  echo "---server log---" >&2
  tail -80 "$LOG" >&2
  echo "---resolver.conf---" >&2
  cat "$WORK/resolver.conf" >&2 || true
  echo "---nats-server.conf---" >&2
  cat "$SERVER_CONF" >&2 || true
  KEEP_WORK=1
  exit 1
}
ok "nats-server up on :$NATS_PORT (container $CONTAINER)"

# ── Step 7: ACL parity tests ───────────────────────────────────────
note "step 7/8: ACL parity — allow + deny cases per role"

NATS_URL="nats://127.0.0.1:$NATS_PORT"
PASS=0; FAILED=0

run_case() {
  local label="$1" expect="$2" role="$3" verb="$4" subj="$5"
  local out rc
  set +e
  if [[ "$verb" == "pub" ]]; then
    out="$("$TIMEOUT" 5 nats --server="$NATS_URL" --creds="$CREDS_DIR/$role.creds" pub --count=1 "$subj" x 2>&1)"
    rc=$?
  else
    out="$("$TIMEOUT" 5 nats --server="$NATS_URL" --creds="$CREDS_DIR/$role.creds" sub --count=1 "$subj" 2>&1)"
    rc=$?
  fi
  set -e
  local got=allow
  if echo "$out" | grep -qiE 'permissions violation|not authorized|user authorization|not allowed'; then
    got=deny
  elif [[ $rc -ne 0 && "$verb" == "pub" ]]; then
    got=deny
  fi
  if [[ "$got" == "$expect" ]]; then
    ok "$label  ($role $verb $subj → $got)"
    PASS=$((PASS+1))
  else
    fail "$label  ($role $verb $subj → got=$got expect=$expect)"
    fail "  output: ${out//$'\n'/ | }"
    FAILED=$((FAILED+1))
  fi
}

# Allow cases
run_case "sysadmin pub-any"        allow sysadmin pub "anything.goes"
run_case "mihai pub state.project" allow mihai    pub "state.project.alpha"
run_case "vahid pub events"        allow vahid    pub "agents.vahid.events"
run_case "sara pub board.tasks.ui" allow sara     pub "board.tasks.ui.foo"

# Deny cases (forge attempts)
run_case "vahid forge tasks.pending" deny vahid pub "board.tasks.python.pending"
run_case "sara  forge tasks.pending" deny sara  pub "board.tasks.ui.pending"
run_case "mihai forge results"       deny mihai pub "board.results.x"
run_case "vahid forge mihai-only"    deny vahid pub "state.project.x"
run_case "sara  forge wrong-domain"  deny sara  pub "board.tasks.python.foo"
run_case "vahid forge KV-policy"     deny vahid pub "\$KV.${KV}.policy.x"
run_case "sara  forge a2a-other"     deny sara  pub "a2a.vahid.tasks.send"

echo
note "step 8/8: summary"
echo "  PASS=$PASS  FAIL=$FAILED"
if [[ $FAILED -ne 0 ]]; then
  fail "ACL parity check FAILED"
  echo "  work dir kept at: $WORK"
  KEEP_WORK=1
  exit 1
fi
ok "ACL parity check OK"
