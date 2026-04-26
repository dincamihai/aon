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
  maya)  SUBJECTS=("a2a.>" "agents.maya.inbox" "agents.*.events" "broadcast.>" "state.alert.>") ;;
  *)     SUBJECTS=("a2a.$HOOK_ROLE.tasks.>" "agents.$HOOK_ROLE.inbox" "broadcast.>") ;;
esac

# Run children in their own process group so a single SIGTERM tears them down.
set -m

cleanup() {
  kill -TERM 0 2>/dev/null || true
}
trap cleanup TERM INT EXIT

echo "[role-monitor] role=$HOOK_ROLE subjects=${SUBJECTS[*]}"

for subj in "${SUBJECTS[@]}"; do
  (
    while IFS= read -r line; do
      printf '[%s] %s\n' "$subj" "$line"
    done < <(stdbuf -oL "$NATS_BIN" --server "$HOOK_NATS_URL" --user "$HOOK_ROLE" --password "$HOOK_PASS" sub "$subj" 2>&1)
  ) &
done

wait
