#!/usr/bin/env bash
# Shared helpers for team-alpha Claude Code hooks.
# Sourced by each hook script. Soft-fails on missing env (warn + exit 0).

set -u

# ── Repo root ──
HOOK_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── Role + identity ──
# Resolve role from (1) env, (2) cwd basename if it's a known role.
HOOK_ROLE="${TEAM_ALPHA_ROLE:-}"
if [ -z "$HOOK_ROLE" ]; then
  case "${PWD##*/}" in
    maya|raj|lin|sam|diego|priya|mihai|vahid) HOOK_ROLE="${PWD##*/}" ;;
  esac
fi
case "$HOOK_ROLE" in
  maya|raj|lin|sam|diego|priya|mihai|vahid) : ;;
  "") echo "WARN: TEAM_ALPHA_ROLE not set + cwd not a role dir — hooks no-op." >&2; exit 0 ;;
  *)  echo "WARN: TEAM_ALPHA_ROLE='$HOOK_ROLE' not in known roster — hooks no-op." >&2; exit 0 ;;
esac

# ── NATS connection ──
HOOK_NATS_URL="${TEAM_ALPHA_NATS_URL:-nats://localhost:4222}"
HOOK_KV_BUCKET="${TEAM_ALPHA_KV_BUCKET:-team-state}"

HOOK_CREDS="${TEAM_ALPHA_CREDS:-$HOME/.team-alpha/$HOOK_ROLE.password}"
[ -r "$HOOK_CREDS" ] \
  || { echo "WARN: creds unreadable ($HOOK_CREDS) — hooks no-op." >&2; exit 0; }

HOOK_PASS="$(tr -d '[:space:]' < "$HOOK_CREDS" 2>/dev/null)"
[ -z "$HOOK_PASS" ] && { echo "WARN: empty creds file — hooks no-op." >&2; exit 0; }

NATS_BIN="${NATS_BIN:-nats}"
command -v "$NATS_BIN" >/dev/null 2>&1 \
  || { echo "WARN: nats CLI not on PATH — hooks no-op." >&2; exit 0; }

# Run nats CLI as this role.
nats_role() {
  "$NATS_BIN" --server "$HOOK_NATS_URL" --user "$HOOK_ROLE" --password "$HOOK_PASS" "$@"
}

# Publish to a subject; swallow errors (publish failures must NEVER block tools).
hook_pub() {
  local subject="$1" payload="$2"
  nats_role pub "$subject" "$payload" >/dev/null 2>&1 || true
}

# KV upsert; swallow errors.
hook_kv_put() {
  local key="$1" value="$2"
  echo -n "$value" | nats_role kv put "$HOOK_KV_BUCKET" "$key" >/dev/null 2>&1 || true
}

now_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
read_stdin() { cat; }

# ── Cursor management for catch-up ──
HOOK_CURSOR_DIR="$HOME/.team-alpha"
HOOK_CURSOR_FILE="$HOOK_CURSOR_DIR/last-seen-$HOOK_ROLE"
mkdir -p "$HOOK_CURSOR_DIR" 2>/dev/null || true

# Subscriptions per role (subject patterns to scan in catch-up).
hook_role_subjects() {
  echo "agents.$HOOK_ROLE.inbox"
  echo "broadcast.>"
  case "$HOOK_ROLE" in
    maya|mihai)  echo "agents.*.events"; echo "state.alert.>" ;;
    raj|vahid)   echo "board.tasks.*.pending"; echo "board.learning.*.pending"; echo "board.learning.*.mentoring" ;;
    lin)   echo "board.tasks.python.pending"; echo "board.tasks.ui.pending"; echo "board.tasks.go.pending"; echo "board.learning.go.>" ;;
    sam)   echo "board.tasks.ui.pending"; echo "board.learning.python.pending"; echo "board.learning.go.pending"; echo "board.learning.python.mentoring"; echo "board.learning.go.mentoring" ;;
    diego) echo "board.tasks.go.pending"; echo "board.learning.terraform.>"; echo "board.learning.aws.>" ;;
    priya) echo "board.tasks.terraform.pending"; echo "board.tasks.aws.pending"; echo "board.learning.python.>" ;;
  esac
}
