#!/usr/bin/env bash
# Shared helpers for aon Claude Code hooks.
# Sourced by each hook script. Soft-fails on missing env (warn + exit 0).

set -u

# ── Repo root ──
# Use cwd (where Claude is running), not script location (which is engine repo).
HOOK_REPO_ROOT="${HOOK_REPO_ROOT:-$(cd "${PWD:-.}" && git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Only activate in aon-configured directories (must have aon.toml).
# Hooks are installed globally in ~/.claude/settings.json so they fire
# for every Claude session; this guard makes them no-ops outside aon repos.
# HOOK_REPO_ROOT resolves to git root, so starting Claude from any subdir
# of an aon repo correctly activates hooks — this is intentional.
[ -f "$HOOK_REPO_ROOT/aon.toml" ] || exit 0

# ── Role + identity ──
# Roster is dynamic (aon.toml) — don't hardcode. NATS auth.conf is the
# real boundary; if the role is unknown there, the publish fails loud.
# AON_ROLE env is the single source of truth — set by aon launch/connect.
# .claude/role is gitignored and no longer written or read.
HOOK_ROLE="${AON_ROLE:-}"
[ -n "$HOOK_ROLE" ] || exit 0

# Resolve team name from aon.toml first, fall back to AON_TEAM env.
_hook_team_name() {
  local toml="$HOOK_REPO_ROOT/aon.toml"
  [ -f "$toml" ] || return 1
  awk '
    /^\[team\]/ { in_team=1; next }
    in_team && /^\[/ { exit }
    in_team && /^[[:space:]]*name[[:space:]]*=/ {
      gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); gsub(/ /, ""); print; exit
    }
  ' "$toml"
}
HOOK_TEAM="$(_hook_team_name)"
HOOK_TEAM="${HOOK_TEAM:-${AON_TEAM:-}}"
[ -n "$HOOK_TEAM" ] || { echo "WARN: cannot resolve team — set AON_TEAM or add [team].name in aon.toml" >&2; exit 0; }

# Subject prefix from aon.toml — namespaces subjects for team isolation.
_hook_subject_prefix() {
  local toml="$HOOK_REPO_ROOT/aon.toml"
  if [ -f "$toml" ]; then
    awk -F= '/^[[:space:]]*subject_prefix[[:space:]]*=/ {
      gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); gsub(/ /, ""); print; exit
    }' "$toml"
  fi
}
HOOK_SUBJECT_PREFIX="$(_hook_subject_prefix)"
HOOK_SUBJECT_PREFIX="${HOOK_SUBJECT_PREFIX%.}"

# Cursor directory — one file per role, shared across roles on this host.
HOOK_CURSOR_DIR="$HOME/.aon/teams/$HOOK_TEAM/cursors"

# Parse rostered role names from aon.toml in the team repo.
# Only names under [[roles]] sections — skips [team].name and other keys.
_hook_roster_from_toml() {
  local toml="$HOOK_REPO_ROOT/aon.toml"
  [ -f "$toml" ] || return
  awk '/^\[\[roles/{r=1;next} /^\[/{r=0;next} r && /^[[:space:]]*name[[:space:]]*=/{
    gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); print
  }' "$toml"
}

# Prune cursor files only for roles no longer in the roster.
# Never delete peers sharing this host — they need their own history.
for _stale_cursor in "$HOOK_CURSOR_DIR"/last-seen-*; do
  [ -f "$_stale_cursor" ] || continue
  _stale_role="${_stale_cursor##*last-seen-}"
  [ "$_stale_role" = "$HOOK_ROLE" ] && continue
  _hook_roster_from_toml | grep -qxF "$_stale_role" || rm -f "$_stale_cursor" 2>/dev/null || true
done
unset _stale_cursor _stale_role

# ── NATS connection ──
# Source team env file so migrated URLs override any stale shell-level
# AON_NATS_URL. Team env is the authoritative source; shell env may carry
# a value from before a URL migration (e.g. :4322 → :4222).
_team_env="$HOME/.aon/teams/$HOOK_TEAM/$(basename "$HOOK_REPO_ROOT").env"
# shellcheck disable=SC1090
[ -f "$_team_env" ] && source "$_team_env"
unset _team_env
HOOK_NATS_URL="${AON_NATS_URL:-nats://localhost:4222}"
HOOK_KV_BUCKET="${AON_KV_BUCKET:-team-state}"

# Default to the registry-resolved creds path. In VM (sandbox) contexts
# creds live at /etc/team-alpha/creds/<role>.creds — try that as fallback
# when the host-style path doesn't exist (works with or without $AON_CREDS).
HOOK_CREDS="${AON_CREDS:-$HOME/.aon/teams/$HOOK_TEAM/creds/$HOOK_ROLE.creds}"
if [ ! -r "$HOOK_CREDS" ]; then
  _vm_creds="/etc/team-alpha/creds/$HOOK_ROLE.creds"
  [ -r "$_vm_creds" ] && HOOK_CREDS="$_vm_creds"
  unset _vm_creds
fi
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

# Publish file contents to a subject via stdin (avoids arg-length limits and quoting issues).
hook_pub_file() {
  local subject="$1" file="$2"
  nats_role pub "$subject" < "$file" >/dev/null 2>&1 || true
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

# Subject prefix helper — prepend HOOK_SUBJECT_PREFIX when set.
_hook_p() {
  if [ -n "$HOOK_SUBJECT_PREFIX" ]; then
    echo "${HOOK_SUBJECT_PREFIX}.${1}"
  else
    echo "$1"
  fi
}

# Subscriptions per role (subject patterns to scan in catch-up).
hook_role_subjects() {
  _hook_p "agents.$HOOK_ROLE.inbox"
  _hook_p "broadcast.>"
  case "$HOOK_ROLE" in
    sun|mihai|mid)  _hook_p "agents.*.events"; _hook_p "state.alert.>" ;;
    tim|joana)      _hook_p "board.tasks.*.pending"; _hook_p "board.learning.*.pending"; _hook_p "board.learning.*.mentoring" ;;
    rona)           _hook_p "board.tasks.*.pending"; _hook_p "board.learning.*.pending" ;;
    ari)            _hook_p "board.tasks.architect.pending"; _hook_p "board.learning.architect.>" ;;
  esac
}
