#!/usr/bin/env bash
# Shared helpers for bootstrap + ops scripts. Sourced, never executed directly.
set -u

: "${NATS_URL:?NATS_URL required (e.g. nats://localhost:4222)}"
: "${NATS_ADMIN_CREDS:?NATS_ADMIN_CREDS required (path to sysadmin .creds — emitted by 'aon creds sysadmin')}"

NATS_BIN="${NATS_BIN:-nats}"

nats_admin() {
  "$NATS_BIN" --server "$NATS_URL" --creds "$NATS_ADMIN_CREDS" "$@"
}

# Retry a command up to N times with backoff. Used to handle the
# resolver reload race: after SIGHUP the NATS server needs a moment
# to propagate the new account JWT before $JS.API.> requests succeed.
_nats_retry() {
  local attempts="${NATS_RETRY_ATTEMPTS:-3}"
  local delay="${NATS_RETRY_DELAY:-2}"
  local n=0
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$attempts" ]; then
      echo "  ✗ command failed after $attempts attempts: $*" >&2
      return 1
    fi
    echo "  ⟳ retrying in ${delay}s (attempt $((n+1))/$attempts)…" >&2
    sleep "$delay"
  done
}

wait_for_nats() {
  local timeout="${1:-30}" elapsed=0
  while ! nats_admin server check connection >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "ERROR: NATS at $NATS_URL not reachable within ${timeout}s" >&2
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

stream_exists() {
  nats_admin stream info "$1" >/dev/null 2>&1
}

kv_exists() {
  nats_admin kv info "$1" >/dev/null 2>&1
}

ensure_stream() {
  # ensure_stream <name> <subjects-csv> <retention> <max-age> [extra args...]
  local name="$1" subjects="$2" retention="$3" max_age="$4"; shift 4
  if stream_exists "$name"; then
    echo "  ✓ stream $name exists"
    return 0
  fi
  _nats_retry nats_admin stream add "$name" \
    --subjects "$subjects" \
    --retention "$retention" \
    --storage file \
    --replicas 1 \
    --discard old \
    --max-age "$max_age" \
    --max-msgs=-1 --max-msgs-per-subject=-1 \
    --max-bytes=-1 --max-msg-size=-1 \
    --dupe-window=2m \
    --no-allow-rollup --no-deny-delete --no-deny-purge \
    --defaults \
    "$@" || return 1
  stream_exists "$name" || { echo "  ✗ stream $name: create command succeeded but stream not visible — resolver not yet propagated" >&2; return 1; }
  echo "  + stream $name created"
}

ensure_audit_stream() {
  # AUDIT sources from named streams. No own subjects.
  local name="AUDIT"
  if stream_exists "$name"; then
    echo "  ✓ stream $name exists"
    return 0
  fi
  local cfg
  cfg=$(mktemp)
  cat > "$cfg" <<'JSON'
{
  "name": "AUDIT",
  "subjects": [],
  "retention": "limits",
  "storage": "file",
  "num_replicas": 1,
  "discard": "old",
  "max_age": 31536000000000000,
  "max_msgs": -1,
  "max_msgs_per_subject": -1,
  "max_bytes": -1,
  "max_msg_size": -1,
  "duplicate_window": 120000000000,
  "sources": [
    {"name": "TASKS"},
    {"name": "LEARNING"},
    {"name": "RESULTS"},
    {"name": "EVENTS"},
    {"name": "A2A_TASKS"}
  ]
}
JSON
  _nats_retry nats_admin stream add --config "$cfg" >/dev/null || { rm -f "$cfg"; return 1; }
  rm -f "$cfg"
  stream_exists "$name" || { echo "  ✗ stream $name: create succeeded but not visible — resolver race" >&2; return 1; }
  echo "  + stream $name created (sources TASKS, LEARNING, RESULTS, EVENTS, A2A_TASKS)"
}

ensure_a2a_disc_stream() {
  # A2A_DISC — discovery cards. Latest one per agent_id only.
  local name="A2A_DISC"
  if stream_exists "$name"; then
    echo "  ✓ stream $name exists"
    return 0
  fi
  _nats_retry nats_admin stream add "$name" \
    --subjects "a2a.discovery.>" \
    --retention limits \
    --storage file \
    --replicas 1 \
    --discard old \
    --max-age 0 \
    --max-msgs=-1 \
    --max-msgs-per-subject=1 \
    --max-bytes=-1 --max-msg-size=-1 \
    --dupe-window=2m \
    --no-allow-rollup --no-deny-delete --no-deny-purge \
    --defaults || return 1
  stream_exists "$name" || { echo "  ✗ stream $name: create succeeded but not visible — resolver race" >&2; return 1; }
  echo "  + stream $name created (max-msgs-per-subject=1)"
}

ensure_kv() {
  # ensure_kv <bucket> <history> <max-age>
  local bucket="$1" history="$2" max_age="$3"
  if kv_exists "$bucket"; then
    echo "  ✓ KV $bucket exists"
    return 0
  fi
  _nats_retry nats_admin kv add "$bucket" \
    --history "$history" \
    --storage file \
    --replicas 1 \
    --ttl "$max_age" || return 1
  kv_exists "$bucket" || { echo "  ✗ KV $bucket: create command succeeded but bucket not visible — resolver not yet propagated" >&2; return 1; }
  echo "  + KV $bucket created"
}

kv_put() {
  # kv_put <bucket> <key> <value>
  local bucket="$1" key="$2" value="$3"
  echo -n "$value" | nats_admin kv put "$bucket" "$key" >/dev/null
}
