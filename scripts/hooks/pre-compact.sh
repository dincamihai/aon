#!/usr/bin/env bash
# PreCompact hook — publish worktree state + context tail for
# post-compaction recovery. AUDIT captures the event; agents read
# it on resume to understand where they left off.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

TS="$(now_iso)"
HOST="$(hostname)"

# Capture worktree state for post-compaction recovery.
WORKTREE=""
BRANCH=""
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  WORKTREE="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
fi

# Capture recent git log for context tail (what the agent did recently).
GIT_LOG=""
if [ -n "$WORKTREE" ]; then
  GIT_LOG="$(git -C "$WORKTREE" log --oneline -5 2>/dev/null || echo "")"
fi

EVT=$(jq -nc --arg r "$HOOK_ROLE" --arg h "$HOST" --arg t "$TS" \
  --arg wt "$WORKTREE" --arg br "$BRANCH" --arg gl "$GIT_LOG" \
  '{type:"recap_request", role:$r, host:$h, timestamp:$t,
    source:"compact", reason:"context window compacting",
    worktree:$wt, branch:$br, recent_log:$gl}')
hook_pub "agents.$HOOK_ROLE.events" "$EVT"

# Identity re-injection + recovery instructions after compaction.
CTX="[POST-COMPACT — You are $HOOK_ROLE. Recovery steps:
1. Re-read agent-prompts/$HOOK_ROLE.md to restore identity.
2. Read your task card via aon-board__get_task (frontmatter has worktree + branch).
3. git diff + git log --oneline -5 in your worktree to see what you did.
4. Use /find-transcript to recover decisions from the previous session.
Resume from last step.]"

jq -nc --arg ctx "$CTX" \
  '{hookSpecificOutput:{hookEventName:"PreCompact",additionalContext:$ctx}}'

exit 0
