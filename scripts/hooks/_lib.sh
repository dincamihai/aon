#!/usr/bin/env bash
# Shared helpers for aon Claude Code hooks.
# Sourced by each hook script. Soft-fails on missing env (warn + exit 0).

set -u

# ── Repo root ──
# Use cwd (where Claude is running), not script location (which is engine repo).
HOOK_REPO_ROOT="${HOOK_REPO_ROOT:-$(cd "${PWD:-.}" && git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ── Role + identity ──
# Roster is dynamic (aon.toml) — don't hardcode. NATS auth.conf is the
# real boundary; if the role is unknown there, the publish fails loud.
# Detect role: prefer .claude/role file (written by aon launch, always fresh),
# fall back to env (for direct hook invocations outside aon launch).
HOOK_ROLE=""
if [ -f "$HOOK_REPO_ROOT/.claude/role" ]; then
  HOOK_ROLE="$(cat "$HOOK_REPO_ROOT/.claude/role" 2>/dev/null)"
fi
[ -z "$HOOK_ROLE" ] && HOOK_ROLE="${AON_ROLE:-}"
[ -n "$HOOK_ROLE" ] || {
  echo "WARN: no .claude/role file and AON_ROLE not set — hooks no-op." >&2
  exit 0
}
HOOK_TEAM="${AON_TEAM:-team-alpha}"

# Sanity check: if AON_ROLE was empty but we have a stale cursor file,
# refuse to use it. Cursor files are per-role; wrong role = wrong history.
HOOK_CURSOR_DIR="$HOME/.aon/teams/$HOOK_TEAM/cursors"
for stale_cursor in "$HOOK_CURSOR_DIR"/last-seen-*; do
  [ -f "$stale_cursor" ] || continue
  stale_role="${stale_cursor##*last-seen-}"
  [ "$stale_role" != "$HOOK_ROLE" ] && rm -f "$stale_cursor" "$HOOK_CURSOR_DIR"/*-"$stale_role" 2>/dev/null || true
done

# ── NATS connection ──
HOOK_NATS_URL="${AON_NATS_URL:-nats://localhost:4222}"
HOOK_KV_BUCKET="${AON_KV_BUCKET:-team-state}"

# Default to the registry-resolved creds path.
HOOK_CREDS="${AON_CREDS:-$HOME/.aon/teams/$HOOK_TEAM/creds/$HOOK_ROLE.creds}"
[ -r "$HOOK_CREDS" ] \
  || { echo "WARN: creds unreadable ($HOOK_CREDS) — hooks no-op." >&2; exit 0; }
[ -s "$HOOK_CREDS" ] \
  || { echo "WARN: empty creds file ($HOOK_CREDS) — hooks no-op." >&2; exit 0; }

NATS_BIN="${NATS_BIN:-nats}"
command -v "$NATS_BIN" >/dev/null 2>&1 \
  || { echo "WARN: nats CLI not on PATH — hooks no-op." >&2; exit 0; }

# Run nats CLI as this role (--creds carries identity + signing key).
nats_role() {
  "$NATS_BIN" --server "$HOOK_NATS_URL" --creds "$HOOK_CREDS" "$@"
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
