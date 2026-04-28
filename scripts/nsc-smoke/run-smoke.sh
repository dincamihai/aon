#!/usr/bin/env bash
# scripts/nsc-smoke/run-smoke.sh
#
# S1 of `.tasks/nsc-jwt-migration.md`: prove the full NSC/JWT chain
# end-to-end against fixture teams. No engine integration here —
# this is a standalone correctness check.
#
# Phases (each runs the full pipeline + ACL parity tests):
#
#   A. Memory resolver  + roster A (alice/bob/carol — fixture names)
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
  "alice|manager||"
  "bob|generalist|python|"
  "carol|specialist|ui|go"
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

# ───────────────────────────────────────────────────────────────────
# Phase C — production templates (S2 verification)
#
# Validates that templates/nats-server.conf substitutes correctly and
# that scripts/bootstrap.sh + scripts/lib/nats-helpers.sh work in
# JWT mode using --creds. Mounts use the shape that
# templates/docker-compose.yml.tmpl produces:
#   /etc/nats/nats-server.conf  (rendered template)
#   /etc/nats/runtime/resolver/<team-id>.jwt  (account JWT)
# ───────────────────────────────────────────────────────────────────
ROSTER_C=(
  "sysadmin|sysadmin||"
  "dora|manager||"
  "evan|generalist|python|"
)
ENGINE_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

run_phase_template() {
  local team="$1"
  shift
  local roster=("$@")
  local kv="${team}-state"

  phase "PHASE C: production templates  team=$team  roles=${#roster[@]}"

  CURRENT_WORK="$(mktemp -d "$WORK_ROOT/${team}.tmpl.XXXXXX")"
  CURRENT_KEEP=0
  local W="$CURRENT_WORK"
  mkdir -p "$W/data" "$W/runtime/resolver" "$W/creds"

  export XDG_DATA_HOME="$W/xdg-data"
  export XDG_CONFIG_HOME="$W/xdg-config"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

  note "step 1/5: NSC scaffold (operator + account + ${#roster[@]} users)"
  nsc add operator --generate-signing-key --sys "$OP" >/dev/null
  nsc edit operator --service-url "nats://127.0.0.1:$NATS_PORT" >/dev/null
  nsc add account "$team" >/dev/null
  nsc edit account "$team" \
    --js-mem-storage 64M --js-disk-storage 256M \
    --js-streams 32 --js-consumer 64 >/dev/null

  local row name kind domain learning
  for row in "${roster[@]}"; do
    IFS='|' read -r name kind domain learning <<<"$row"
    add_user "$team" "$kv" "$name" "$kind" "$domain" "$learning"
    nsc generate creds --account "$team" --name "$name" > "$W/creds/$name.creds"
    chmod 600 "$W/creds/$name.creds"
  done

  note "step 2/5: render templates/nats-server.conf"
  local OP_JWT SYS_ID SYS_JWT TEAM_ID TEAM_JWT
  OP_JWT="$(nsc describe operator --raw 2>/dev/null | tr -d '\n')"
  SYS_ID="$(nsc describe account --name SYS --field sub 2>/dev/null | tr -d '"')"
  SYS_JWT="$(nsc describe account --name SYS --raw 2>/dev/null | tr -d '\n')"
  TEAM_ID="$(nsc describe account --name "$team" --field sub 2>/dev/null | tr -d '"')"
  TEAM_JWT="$(nsc describe account --name "$team" --raw 2>/dev/null | tr -d '\n')"
  printf '%s' "$TEAM_JWT" > "$W/runtime/resolver/$TEAM_ID.jwt"

  local TPL="$ENGINE_DIR/templates/nats-server.conf"
  [[ -r "$TPL" ]] || { fail "template missing: $TPL"; CURRENT_KEEP=1; return 1; }
  # `|` delimiter in sed; OP_JWT/SYS_JWT contain alnum + `.` + `_` + `-`.
  sed -e "s|@OP_JWT@|$OP_JWT|g" \
      -e "s|@SYS_ID@|$SYS_ID|g" \
      -e "s|@SYS_JWT@|$SYS_JWT|g" \
      -e "s|@TEAM_NAME@|$team|g" \
      "$TPL" > "$W/nats-server.conf"

  # Sanity: no placeholders left.
  if grep -E '@(OP_JWT|SYS_ID|SYS_JWT|TEAM_NAME)@' "$W/nats-server.conf" >/dev/null; then
    fail "unsubstituted placeholders remain in rendered nats-server.conf"
    CURRENT_KEEP=1
    return 1
  fi

  note "step 3/5: boot nats:latest with prod-shape mounts"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER" \
    -p ${NATS_PORT}:4222 \
    -e AON_SERVER_NAME="${team}-1" \
    -v "$W/nats-server.conf":/etc/nats/nats-server.conf:ro \
    -v "$W/runtime":/etc/nats/runtime:ro \
    -v "$W/data":/data \
    nats:latest \
    --config /etc/nats/nats-server.conf \
    -DV >/dev/null || { fail "docker run failed"; CURRENT_KEEP=1; return 1; }

  local i
  for i in $(seq 1 30); do
    if docker logs "$CONTAINER" 2>&1 | grep -q 'Server is ready'; then break; fi
    sleep 0.3
  done
  if ! docker logs "$CONTAINER" 2>&1 | grep -q 'Server is ready'; then
    fail "server not ready (template phase)"
    docker logs "$CONTAINER" 2>&1 | tail -60 >&2
    CURRENT_KEEP=1
    return 1
  fi
  ok "nats-server up (rendered template)"

  note "step 4/5: ACL parity"
  run_acl_tests "$team" "$kv" "$W/creds" "${roster[@]}"

  note "step 5/5: bootstrap.sh + nats-helpers.sh under --creds"
  local boot_log="$W/bootstrap.log"
  local roster_names=""
  for row in "${roster[@]}"; do
    IFS='|' read -r name kind _ _ <<<"$row"
    [[ "$kind" == "sysadmin" ]] && continue
    roster_names+="${roster_names:+ }$name"
  done
  set +e
  NATS_URL="nats://127.0.0.1:$NATS_PORT" \
  NATS_ADMIN_CREDS="$W/creds/sysadmin.creds" \
  AON_ROSTER="$roster_names" \
  AON_KV_BUCKET="$kv" \
  "$ENGINE_DIR/scripts/bootstrap.sh" >"$boot_log" 2>&1
  local boot_rc=$?
  set -e
  if [[ $boot_rc -eq 0 ]]; then
    ok "bootstrap.sh succeeded under --creds"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    fail "bootstrap.sh failed (rc=$boot_rc)"
    tail -30 "$boot_log" >&2
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    CURRENT_KEEP=1
  fi

  docker rm -f "$CONTAINER" >/dev/null 2>&1
  return 0
}

# ───────────────────────────────────────────────────────────────────
# Phase D — revoke takes effect on a live nats-server
#
# Proves the rotation primitive that `aon revoke` wraps:
#   1. Mint operator + account + 1 user, emit .creds.
#   2. Boot dir-resolver server (interval=2s for fast test).
#   3. Pub allow → succeeds.
#   4. nsc revocations add-user + republish team JWT + SIGHUP.
#   5. Pub from SAME .creds → must reject.
#   6. nsc revocations delete-user + republish + SIGHUP.
#   7. Pub → succeeds again.
# ───────────────────────────────────────────────────────────────────
run_phase_revoke() {
  local team="team-aon-smoke-d"
  local kv="${team}-state"
  local role="evan"

  phase "PHASE D: revoke takes effect  team=$team  role=$role"

  CURRENT_WORK="$(mktemp -d "$WORK_ROOT/${team}.revoke.XXXXXX")"
  CURRENT_KEEP=0
  local W="$CURRENT_WORK"
  mkdir -p "$W/data" "$W/jwt" "$W/creds"

  export XDG_DATA_HOME="$W/xdg-data"
  export XDG_CONFIG_HOME="$W/xdg-config"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

  note "step 1/7: NSC scaffold (operator + account + $role)"
  nsc add operator --generate-signing-key --sys "$OP" >/dev/null
  nsc edit operator --service-url "nats://127.0.0.1:$NATS_PORT" >/dev/null
  nsc add account "$team" >/dev/null
  nsc edit account "$team" \
    --js-mem-storage 64M --js-disk-storage 256M \
    --js-streams 32 --js-consumer 64 >/dev/null
  add_user "$team" "$kv" "$role" generalist python ""
  nsc generate creds --account "$team" --name "$role" > "$W/creds/$role.creds"
  chmod 600 "$W/creds/$role.creds"

  note "step 2/7: build dir-resolver config (interval=2s for fast pickup)"
  local OP_JWT SYS_ID SYS_JWT TEAM_ID TEAM_JWT
  OP_JWT="$(nsc describe operator --raw 2>/dev/null | tr -d '\n')"
  SYS_ID="$(nsc describe account --name SYS --field sub 2>/dev/null | tr -d '"')"
  SYS_JWT="$(nsc describe account --name SYS --raw 2>/dev/null | tr -d '\n')"
  TEAM_ID="$(nsc describe account --name "$team" --field sub 2>/dev/null | tr -d '"')"
  TEAM_JWT="$(nsc describe account --name "$team" --raw 2>/dev/null | tr -d '\n')"
  printf '%s' "$TEAM_JWT" > "$W/jwt/$TEAM_ID.jwt"

  cat > "$W/nats-server.conf" <<EOF
port: 4222
http: 8222
jetstream: { store_dir: "/work/data" }

operator: $OP_JWT
system_account: $SYS_ID
resolver: {
  type: full
  dir: "/work/jwt"
  allow_delete: false
  interval: "2s"
}
resolver_preload: {
  $SYS_ID: $SYS_JWT
}
EOF

  note "step 3/7: boot nats:latest"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER" \
    -p ${NATS_PORT}:4222 \
    -v "$W":/work \
    nats:latest \
    --config /work/nats-server.conf >/dev/null \
    || { fail "docker run failed"; CURRENT_KEEP=1; return 1; }
  local i
  for i in $(seq 1 30); do
    if docker logs "$CONTAINER" 2>&1 | grep -q 'Server is ready'; then break; fi
    sleep 0.3
  done
  if ! docker logs "$CONTAINER" 2>&1 | grep -q 'Server is ready'; then
    fail "server not ready"; docker logs "$CONTAINER" 2>&1 | tail -40 >&2
    CURRENT_KEEP=1; return 1
  fi
  ok "nats-server up"

  local URL="nats://127.0.0.1:$NATS_PORT"
  local CREDS="$W/creds/$role.creds"
  local SUBJ="agents.$role.events"

  note "step 4/7: pre-revoke pub (must succeed)"
  if "$TIMEOUT" 5 nats --server "$URL" --creds "$CREDS" pub --count=1 "$SUBJ" pre 2>&1 | grep -q "Published"; then
    ok "pre-revoke pub allowed"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    fail "pre-revoke pub denied unexpectedly"
    TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1
  fi

  note "step 5/7: nsc revocations add-user + nsc push (\$SYS.REQ.CLAIMS.UPDATE)"
  # Revoke at "now+1" (the at-flag uses ≤; equality counts) so credentials
  # issued moments ago are clearly older than the cutoff.
  local NOW1; NOW1=$(( $(date +%s) + 1 ))
  nsc revocations add-user --account "$team" --name "$role" --at "$NOW1" >/dev/null \
    || { fail "nsc revocations add-user failed"; TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1; return 1; }
  # Sanity: revocation actually landed in the in-store JWT.
  if ! nsc describe account --name "$team" --field nats.revocations 2>/dev/null \
       | grep -q '"'; then
    fail "account JWT has no revocations map after add-user"
    TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1
  fi
  # Push to the running server via \$SYS.REQ.CLAIMS.UPDATE. Disk-only
  # rewrite is not picked up at runtime — the resolver dir is server-write,
  # not server-read mid-run. SYS user is auto-generated by nsc add operator
  # --sys; nsc push uses it implicitly.
  if ! nsc push -a "$team" -u "nats://127.0.0.1:$NATS_PORT" >/dev/null 2>&1; then
    fail "nsc push failed (could not reach server on :$NATS_PORT)"
    TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1
    return 1
  fi

  note "step 6/7: post-revoke pub (must reject; poll up to 10s)"
  local out rc got=allow tries=0
  while (( tries < 20 )); do
    set +e
    out="$("$TIMEOUT" 5 nats --server "$URL" --creds "$CREDS" pub --count=1 "$SUBJ" post 2>&1)"
    rc=$?
    set -e
    if echo "$out" | grep -qiE 'authorization|not authorized|user authentication revoked|permissions violation' \
       || [[ $rc -ne 0 ]]; then
      got=deny
      break
    fi
    sleep 0.5
    tries=$((tries+1))
  done
  if [[ "$got" == "deny" ]]; then
    ok "post-revoke pub rejected (waited $((tries*5/10))s)"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    fail "post-revoke pub UNEXPECTEDLY allowed after 10s: ${out//$'\n'/ | }"
    TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1
  fi

  note "step 7/7: clear revocation + nsc push + re-issue creds + re-pub (must succeed)"
  nsc revocations delete-user --account "$team" --name "$role" >/dev/null \
    || { fail "nsc revocations delete-user failed"; TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1; return 1; }
  if ! nsc push -a "$team" -u "nats://127.0.0.1:$NATS_PORT" >/dev/null 2>&1; then
    fail "nsc push (clear) failed"
    TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1
    return 1
  fi
  # Re-issue creds (revocation invalidated the prior issued_at).
  nsc generate creds --account "$team" --name "$role" > "$CREDS"
  chmod 600 "$CREDS"
  if "$TIMEOUT" 5 nats --server "$URL" --creds "$CREDS" pub --count=1 "$SUBJ" cleared 2>&1 | grep -q "Published"; then
    ok "post-clear pub allowed"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    fail "post-clear pub denied unexpectedly"
    TOTAL_FAIL=$((TOTAL_FAIL+1)); CURRENT_KEEP=1
  fi

  docker rm -f "$CONTAINER" >/dev/null 2>&1
  return 0
}


# ── Run phases ─────────────────────────────────────────────────────
run_phase memory team-aon-smoke-a "${ROSTER_A[@]}"
run_phase dir    team-aon-smoke-b "${ROSTER_B[@]}"
run_phase_template team-aon-smoke-c "${ROSTER_C[@]}"
run_phase_revoke

echo
phase "FINAL"
echo "  total PASS=$TOTAL_PASS  FAIL=$TOTAL_FAIL"
if [[ $TOTAL_FAIL -ne 0 ]]; then
  fail "smoke FAILED"
  exit 1
fi
ok "smoke OK"
