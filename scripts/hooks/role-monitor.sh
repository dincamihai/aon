#!/usr/bin/env bash
# Multiplexed NATS Monitor for an aon role.
# Spawns one `nats sub` per role-relevant subject in parallel, tags each
# line with `[<subject>]` and merges into stdout. Designed to run inside
# a single Claude Code Monitor tool invocation.
#
# Usage:
#   role-monitor.sh                # role from $AON_ROLE or cwd basename
#   role-monitor.sh <role>         # explicit
#
# Stop with Ctrl-C / TaskStop — kills the whole process group.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${1:-}" ] && HOOK_ROLE="$1"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
# _lib.sh reads AON_ROLE env (sole source of truth — .claude/role not used).
# When an explicit arg was given, override env so the caller wins.
if [ -n "${1:-}" ]; then
  HOOK_ROLE="$1"
  # Re-resolve team from aon.toml — AON_TEAM env may be stale
  HOOK_TEAM="${AON_TEAM:-$(_hook_team_name)}"
  [ -n "$HOOK_TEAM" ] || { echo "[role-monitor] ERROR: cannot resolve team — set AON_TEAM or add [team].name in aon.toml" >&2; exit 2; }
  HOOK_CREDS="$HOME/.aon/teams/$HOOK_TEAM/creds/$HOOK_ROLE.creds"
  # VM (sandbox) fallback: creds at /etc/team-alpha/creds/<role>.creds via ACL.
  if [ ! -r "$HOOK_CREDS" ]; then
    _vm_creds="/etc/team-alpha/creds/$HOOK_ROLE.creds"
    [ -r "$_vm_creds" ] && HOOK_CREDS="$_vm_creds"
    unset _vm_creds
  fi
fi

_prefix() { [ -n "$HOOK_SUBJECT_PREFIX" ] && echo "${HOOK_SUBJECT_PREFIX}.${1}" || echo "$1"; }
case "$HOOK_ROLE" in
  sun|mihai|mid)  SUBJECTS=("$(_prefix "a2a.>")" "$(_prefix "agents.$HOOK_ROLE.inbox")" "$(_prefix "agents.*.events")" "$(_prefix "broadcast.>")" "$(_prefix "state.alert.>")") ;;
  *)     SUBJECTS=("$(_prefix "a2a.$HOOK_ROLE.tasks.>")" "$(_prefix "agents.$HOOK_ROLE.inbox")" "$(_prefix "broadcast.>")") ;;
esac

# Cleanup: kill every descendant by walking the process tree from $$.
# Process substitution + pipelines + bash subshells make naive
# `kill -TERM 0` unreliable; pgrep-based recursion catches them all.
kill_tree() {
  local parent="$1" child
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$parent" 2>/dev/null || true
}

cleanup() {
  for child in $(pgrep -P $$ 2>/dev/null); do
    kill_tree "$child"
  done
  # Belt-and-suspenders for stragglers.
  pkill -TERM -f "nats.*${HOOK_CREDS}.*sub" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

echo "[role-monitor] role=$HOOK_ROLE pid=$$ subjects=${SUBJECTS[*]}"

# Pre-flight handshake — fail fast and loud when tunnel/auth is down,
# instead of silently exiting after each `nats sub` dies.
_event_subj="$(_prefix "agents.$HOOK_ROLE.events")"
if ! "$NATS_BIN" --server "$HOOK_NATS_URL" --creds "$HOOK_CREDS" \
    --timeout 5s pub "$_event_subj" '{"k":"monitor-probe"}' >/dev/null 2>&1; then
  echo "[role-monitor] ✗ NATS unreachable at $HOOK_NATS_URL (role=$HOOK_ROLE)" >&2
  echo "[role-monitor]   Common causes: tunnel down, wrong bits, account JWT not pushed." >&2
  echo "[role-monitor]   Diagnose:  nats --server $HOOK_NATS_URL --creds $HOOK_CREDS --timeout 5s pub $_event_subj '{}'" >&2
  exit 2
fi

for subj in "${SUBJECTS[@]}"; do
  (
    "$NATS_BIN" --server "$HOOK_NATS_URL" --creds "$HOOK_CREDS" \
      sub "$subj" 2>&1 \
      | stdbuf -oL sed -u "s|^|[$subj] |"
  ) &
done

wait
