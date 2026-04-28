#!/usr/bin/env bash
# scripts/nsc-smoke/run-smoke.sh
#
# S1 of `.tasks/nsc-jwt-migration.md`: prove the full NSC/JWT chain
# end-to-end against fixture teams. No engine integration here —
# this is a standalone correctness check.
#
# Phases (each runs the full pipeline + ACL parity tests):
#
#   A. Memory resolver  + roster A (mihai/vahid/sara)
#      → fast path, smallest moving parts; covers all 4 kinds.
#   B. Dir resolver     + roster B (raj/lin/sam/diego/priya)
#      → matches the production cutover shape (resolver: full, dir:);
#        also exercises a different name set + extra specialist to
#        catch role-name escaping issues.
#
# Each phase: spin up a throwaway NSC home (XDG redirect), mint
# operator + account + per-role users with claims translated 1:1
# from templates/auth/*.tmpl, emit .creds, boot a docker
# nats:latest in JWT mode, run allow + forge cases.
#
# Requires: nsc, docker, nats CLI, GNU timeout (gtimeout on macOS via
# `brew install coreutils`). No host nats-server needed.

set -euo pipefail

OP=aon-op
NATS_PORT=14222

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="$SCRIPT_DIR/.work"
mkdir -p "$WORK_ROOT"

CONTAINER="nsc-smoke-$$"
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
[[ -n "$TIMEOUT" ]] || { echo "need GNU timeout (brew install coreutils)" >&2; exit 1; }

CURRENT_WORK=
CURRENT_KEEP=0
TOTAL_PASS=0
TOTAL_FAIL=0

cleanup() {
  set +e
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  if [[ "$CURRENT_KEEP" == "1" && -n "$CURRENT_WORK" ]]; then
    echo "kept work dir: $CURRENT_WORK" >&2
  elif [[ -n "$CURRENT_WORK" ]]; then
    rm -rf "$CURRENT_WORK"
  fi
}
trap cleanup EXIT

note()   { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()     { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
phase()  { printf '\n\033[35m═══ %s ═══\033[0m\n' "$*"; }

# ───────────────────────────────────────────────────────────────────
# Roster format: each entry is "name|kind|domain|learning".
#   - kind ∈ {sysadmin, manager, generalist, specialist}
#   - domain + learning unused for sysadmin/manager.
# ───────────────────────────────────────────────────────────────────

ROSTER_A=(
  "sysadmin|sysadmin||"
  "mihai|manager||"
  "vahid|generalist|python|"
  "sara|specialist|ui|go"
)

ROSTER_B=(
  "sysadmin|sysadmin||"
  "raj|manager||"
  "lin|generalist|go|"
  "sam|specialist|terraform|python"
  "diego|specialist|ui|go"
  "priya|generalist|python|"
)

# Add an NSC user with claims mirroring templates/auth/<kind>.tmpl,
# substituting @ROLE@/@DOMAIN@/@LEARNING@/@KV_BUCKET@.
add_user() {
  local team="$1" kv="$2" name="$3" kind="$4" domain="$5" learning="${6:-$5}"

  case "$kind" in
    sysadmin)
      nsc add user --account "$team" "$name" \
        --allow-pubsub ">" \
        --allow-pub-response >/dev/null
      ;;
    manager)
      nsc add user --account "$team" "$name" \
        --allow-pub "agents.${name}.events,agents.*.inbox,broadcast.>,board.tasks.*.pending,board.tasks.review.>,a2a.*.tasks.send,a2a.*.tasks.*.cancel,a2a.discovery.>,state.project.>,\$KV.${kv}.project.>,\$KV.${kv}.team.>,\$KV.${kv}.policy.>,\$KV.${kv}.agent.${name}.>,state.>,\$JS.API.>,_INBOX.>" \
        --deny-pub "board.results.>" \
        --allow-sub ">" \
        --allow-pub-response >/dev/null
      ;;
    generalist)
      nsc add user --account "$team" "$name" \
        --allow-pub "agents.${name}.events,agents.*.inbox,broadcast.incidents,state.alert.no_human,board.tasks.*.>,board.results.>,board.learning.*.mentoring,board.learning.*.pending,a2a.${name}.tasks.>,a2a.discovery.${name},state.agent.${name}.>,\$KV.${kv}.agent.${name}.>,\$KV.${kv}.a2a.${name}.>,\$JS.API.>" \
        --deny-pub "board.tasks.*.pending" \
        --allow-sub "agents.${name}.inbox,board.tasks.*.pending,board.learning.*.pending,board.learning.*.mentoring,a2a.${name}.tasks.send,a2a.${name}.tasks.*.cancel,a2a.${name}.tasks.>,broadcast.>,state.>,\$KV.${kv}.>,\$JS.API.>,_INBOX.>" \
        --allow-pub-response >/dev/null
      ;;
    specialist)
      nsc add user --account "$team" "$name" \
        --allow-pub "agents.${name}.events,agents.*.inbox,broadcast.incidents,state.alert.no_human,board.tasks.${domain}.>,board.results.${domain}.>,board.learning.${learning}.claimed,a2a.${name}.tasks.>,a2a.discovery.${name},state.agent.${name}.>,\$KV.${kv}.agent.${name}.>,\$KV.${kv}.a2a.${name}.>,\$JS.API.>" \
        --deny-pub "board.tasks.*.pending" \
        --allow-sub "agents.${name}.inbox,board.tasks.${domain}.pending,board.learning.${learning}.pending,board.learning.${learning}.mentoring,a2a.${name}.tasks.send,a2a.${name}.tasks.*.cancel,a2a.${name}.tasks.>,broadcast.>,state.>,\$KV.${kv}.>,\$JS.API.>,_INBOX.>" \
        --allow-pub-response >/dev/null
      ;;
    *)
      fail "unknown kind: $kind ($name)"; return 1 ;;
  esac
}

# Run the full pipeline for one (resolver_mode, team_name, roster) combo.
# resolver_mode ∈ { memory, dir }
run_phase() {
  local mode="$1" team="$2"
  shift 2
  local roster=("$@")
  local kv="${team}-state"

  phase "PHASE: resolver=$mode  team=$team  roles=${#roster[@]}"

  CURRENT_WORK="$(mktemp -d "$WORK_ROOT/${team}.${mode}.XXXXXX")"
  CURRENT_KEEP=0
  local W="$CURRENT_WORK"
  local CREDS_DIR="$W/creds" CONF="$W/nats-server.conf" LOG="$W/nats.log"
  mkdir -p "$CREDS_DIR" "$W/data" "$W/jwt"

  # XDG redirect: per-phase NSC home, no host pollution.
  export XDG_DATA_HOME="$W/xdg-data"
  export XDG_CONFIG_HOME="$W/xdg-config"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

  note "step 1/6: NSC home + operator $OP + account $team"
  nsc add operator --generate-signing-key --sys "$OP" >/dev/null
  nsc edit operator --service-url "nats://127.0.0.1:$NATS_PORT" >/dev/null
  nsc add account "$team" >/dev/null
  nsc edit account "$team" \
    --js-mem-storage 64M --js-disk-storage 256M \
    --js-streams 32 --js-consumer 64 >/dev/null

  note "step 2/6: add ${#roster[@]} users with claim translation"
  local row name kind domain learning
  for row in "${roster[@]}"; do
    IFS='|' read -r name kind domain learning <<<"$row"
    add_user "$team" "$kv" "$name" "$kind" "$domain" "$learning"
  done

  note "step 3/6: emit .creds"
  for row in "${roster[@]}"; do
    IFS='|' read -r name _ _ _ <<<"$row"
    nsc generate creds --account "$team" --name "$name" > "$CREDS_DIR/$name.creds"
    chmod 600 "$CREDS_DIR/$name.creds"
  done

  note "step 4/6: build server config (mode=$mode)"
  local OP_JWT SYS_ID TEAM_ID SYS_JWT TEAM_JWT
  OP_JWT="$(nsc describe operator --raw 2>/dev/null | tr -d '\n')"
  SYS_ID="$(nsc describe account --name SYS --field sub 2>/dev/null | tr -d '"')"
  TEAM_ID="$(nsc describe account --name "$team" --field sub 2>/dev/null | tr -d '"')"
  SYS_JWT="$(nsc describe account --name SYS --raw 2>/dev/null | tr -d '\n')"
  TEAM_JWT="$(nsc describe account --name "$team" --raw 2>/dev/null | tr -d '\n')"
  [[ -n "$OP_JWT" && -n "$SYS_ID" && -n "$TEAM_ID" && -n "$SYS_JWT" && -n "$TEAM_JWT" ]] \
    || { fail "missing JWT/IDs"; CURRENT_KEEP=1; return 1; }

  if [[ "$mode" == "memory" ]]; then
    cat > "$CONF" <<EOF
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
  else
    # Dir resolver: nats-server reads account JWTs from a directory.
    # SYS preloaded in conf; team JWT placed on disk under jwt/.
    printf '%s' "$TEAM_JWT" > "$W/jwt/$TEAM_ID.jwt"
    cat > "$CONF" <<EOF
port: 4222
http: 8222
jetstream: { store_dir: "/work/data" }

operator: $OP_JWT
system_account: $SYS_ID
resolver: {
  type: full
  dir: "/work/jwt"
  allow_delete: false
  interval: "2m"
}
resolver_preload: {
  $SYS_ID: $SYS_JWT
}
EOF
  fi

  note "step 5/6: boot nats:latest"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER" \
    -p ${NATS_PORT}:4222 \
    -v "$W":/work \
    nats:latest \
    --config /work/nats-server.conf \
    -DV >/dev/null || { fail "docker run failed"; CURRENT_KEEP=1; return 1; }

  local i
  for i in $(seq 1 30); do
    if docker logs "$CONTAINER" 2>&1 | grep -q 'Server is ready'; then break; fi
    sleep 0.3
  done
  docker logs "$CONTAINER" > "$LOG" 2>&1 || true
  if ! grep -q 'Server is ready' "$LOG"; then
    fail "server not ready"
    echo "---server log (tail)---" >&2; tail -60 "$LOG" >&2
    echo "---nats-server.conf---" >&2; cat "$CONF" >&2
    CURRENT_KEEP=1
    return 1
  fi
  ok "nats-server up on :$NATS_PORT"

  note "step 6/6: ACL parity"
  run_acl_tests "$team" "$kv" "$CREDS_DIR" "${roster[@]}"

  docker rm -f "$CONTAINER" >/dev/null 2>&1
  return 0
}

# Build a deterministic test set from the roster:
#  - For each role: 1 allow case + 1+ forge (deny) cases.
#  - Plus a few cross-role forges (one role tries another's slot).
run_acl_tests() {
  local team="$1" kv="$2" creds_dir="$3"
  shift 3
  local roster=("$@")
  local NATS_URL="nats://127.0.0.1:$NATS_PORT"
  local pass=0 failed=0

  _case() {
    local label="$1" expect="$2" role="$3" subj="$4"
    local out rc
    set +e
    out="$("$TIMEOUT" 5 nats --server="$NATS_URL" --creds="$creds_dir/$role.creds" pub --count=1 "$subj" x 2>&1)"
    rc=$?
    set -e
    local got=allow
    if echo "$out" | grep -qiE 'permissions violation|not authorized|user authorization|not allowed'; then
      got=deny
    elif [[ $rc -ne 0 ]]; then
      got=deny
    fi
    if [[ "$got" == "$expect" ]]; then
      ok "$label  ($role pub $subj → $got)"
      pass=$((pass+1))
    else
      fail "$label  ($role pub $subj → got=$got expect=$expect)"
      fail "  output: ${out//$'\n'/ | }"
      failed=$((failed+1))
    fi
  }

  local row name kind domain learning
  for row in "${roster[@]}"; do
    IFS='|' read -r name kind domain learning <<<"$row"
    case "$kind" in
      sysadmin)
        _case "$name allow-any"            allow "$name" "anything.goes"
        ;;
      manager)
        _case "$name allow state.project"  allow "$name" "state.project.alpha"
        _case "$name allow KV.policy"      allow "$name" "\$KV.${kv}.policy.x"
        _case "$name forge results"         deny "$name" "board.results.x"
        ;;
      generalist)
        _case "$name allow events"         allow "$name" "agents.${name}.events"
        _case "$name allow board.tasks"    allow "$name" "board.tasks.${domain}.foo"
        _case "$name forge tasks.pending"   deny "$name" "board.tasks.${domain}.pending"
        _case "$name forge state.project"   deny "$name" "state.project.x"
        _case "$name forge KV.policy"       deny "$name" "\$KV.${kv}.policy.x"
        ;;
      specialist)
        _case "$name allow board.tasks.dom" allow "$name" "board.tasks.${domain}.foo"
        _case "$name forge wrong-domain"     deny "$name" "board.tasks.zzz.foo"
        _case "$name forge tasks.pending"    deny "$name" "board.tasks.${domain}.pending"
        _case "$name forge state.project"    deny "$name" "state.project.x"
        ;;
    esac
  done

  # Cross-role forges: pick first non-sysadmin generalist or specialist
  # and have them try a sibling agent's a2a slot.
  local g_name="" g2_name=""
  for row in "${roster[@]}"; do
    IFS='|' read -r name kind _ _ <<<"$row"
    [[ "$kind" == "generalist" || "$kind" == "specialist" ]] || continue
    if [[ -z "$g_name" ]]; then g_name="$name"
    elif [[ -z "$g2_name" ]]; then g2_name="$name"; fi
  done
  if [[ -n "$g_name" && -n "$g2_name" ]]; then
    _case "$g_name forge a2a.$g2_name" deny "$g_name" "a2a.${g2_name}.tasks.send"
  fi

  echo "  phase tally: PASS=$pass  FAIL=$failed"
  TOTAL_PASS=$((TOTAL_PASS+pass))
  TOTAL_FAIL=$((TOTAL_FAIL+failed))
  if [[ $failed -ne 0 ]]; then
    CURRENT_KEEP=1
  fi
}

# ── Run phases ─────────────────────────────────────────────────────
run_phase memory team-aon-smoke-a "${ROSTER_A[@]}"
run_phase dir    team-aon-smoke-b "${ROSTER_B[@]}"

echo
phase "FINAL"
echo "  total PASS=$TOTAL_PASS  FAIL=$TOTAL_FAIL"
if [[ $TOTAL_FAIL -ne 0 ]]; then
  fail "smoke FAILED"
  exit 1
fi
ok "smoke OK"
