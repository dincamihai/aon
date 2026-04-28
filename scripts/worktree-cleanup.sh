#!/usr/bin/env bash
# Remove a per-card worktree after PR merge / abandonment.
#
# Usage:
#   bash scripts/worktree-cleanup.sh <slug>
#   bash scripts/worktree-cleanup.sh --prune       # remove all merged worktrees
set -euo pipefail

CARD_REPO="$(git rev-parse --show-toplevel)"
TASK_DIR="${AON_TASK_DIR:-.tasks}"
WORKER="${AON_ROLE:-$(hostname | tr '[:upper:]' '[:lower:]')}"

# Resolve the code repo for a slug (multi-repo: read repo: from card; legacy: CWD).
resolve_repo_root() {
  local slug="$1"
  local card="$CARD_REPO/$TASK_DIR/$slug.md"
  local repo_field=""
  if [ -f "$card" ]; then
    repo_field=$(awk -F': *' '/^repo:/{print $2; exit}' "$card" | tr -d '[:space:]"' || true)
  fi
  if [ -n "$repo_field" ]; then
    local harness_dir
    harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    bash "$harness_dir/scripts/ensure-clone.sh" "$repo_field"
  else
    echo "$CARD_REPO"
  fi
}

worktrees_root_for() {
  local repo_root="$1"
  local repo_name
  repo_name="$(basename "$repo_root")"
  echo "${AON_WORKTREES_DIR:-$(dirname "$repo_root")/${repo_name}.worktrees}"
}

if [ "${1:-}" = "--prune" ]; then
  WORKER_HOME="${AON_WORKER_HOME:-$HOME/work}"
  for repo_root in "$CARD_REPO" "$WORKER_HOME"/*/.git; do
    [ "$repo_root" = "$WORKER_HOME/*/.git" ] && continue
    repo_root="${repo_root%/.git}"
    [ -d "$repo_root/.git" ] || continue
    cd "$repo_root"
    if git remote | grep -qx host; then
      git fetch host --prune >/dev/null 2>&1 || true
      BASE_REF=$(git rev-parse --verify --quiet host/master >/dev/null && echo host/master || echo host/main)
    else
      git fetch origin --prune >/dev/null 2>&1 || true
      BASE_REF=$(git rev-parse --verify --quiet origin/master >/dev/null && echo origin/master || echo origin/main)
    fi
    for wt in $(git worktree list --porcelain | awk '$1=="worktree"{print $2}'); do
      [ "$wt" = "$repo_root" ] && continue
      BR=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      [ -z "$BR" ] && continue
      if git merge-base --is-ancestor "$BR" "$BASE_REF" 2>/dev/null; then
        git worktree remove "$wt" >/dev/null 2>&1 || true
        echo "removed $wt (merged branch $BR in $repo_root)"
      fi
    done
  done
  exit 0
fi

SLUG="$1"
REPO_ROOT="$(resolve_repo_root "$SLUG")"
WORKTREES_ROOT="$(worktrees_root_for "$REPO_ROOT")"
WT="$WORKTREES_ROOT/$WORKER/$SLUG"
[ -d "$WT" ] || { echo "worktree not found: $WT" >&2; exit 1; }

cd "$REPO_ROOT"
git worktree remove "$WT" >/dev/null 2>&1 || true
git branch -D "$WORKER/$SLUG" 2>/dev/null || true
echo "removed worktree $WT and branch $WORKER/$SLUG"
