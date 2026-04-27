#!/usr/bin/env bash
# Multiplexed NATS Monitor for a team-alpha role.
# Spawns one `nats sub` per role-relevant subject in parallel, tags each
# line with `[<subject>]` and merges into stdout. Designed to run inside
# a single Claude Code Monitor tool invocation.
#
# Usage:
#   role-monitor.sh                # role from $TEAM_ALPHA_ROLE or cwd basename
#   role-monitor.sh <role>         # explicit
#
# Stop with Ctrl-C / TaskStop — kills the whole process group.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

[ -n "${1:-}" ] && HOOK_ROLE="$1"

case "$HOOK_ROLE" in
  maya|mihai)  SUBJECTS=("a2a.>" "agents.$HOOK_ROLE.inbox" "agents.*.events" "broadcast.>" "state.alert.>") ;;
  *)     SUBJECTS=("a2a.$HOOK_ROLE.tasks.>" "agents.$HOOK_ROLE.inbox" "broadcast.>") ;;
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
  pkill -TERM -f "nats.*--user $HOOK_ROLE.*sub" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

echo "[role-monitor] role=$HOOK_ROLE pid=$$ subjects=${SUBJECTS[*]}"

for subj in "${SUBJECTS[@]}"; do
  (
    "$NATS_BIN" --server "$HOOK_NATS_URL" --user "$HOOK_ROLE" --password "$HOOK_PASS" \
      sub "$subj" 2>&1 \
      | stdbuf -oL sed -u "s|^|[$subj] |"
  ) &
done

wait
