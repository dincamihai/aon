#!/usr/bin/env bash
# Atomic card-claim + worktree creation for team-alpha.
#
# Identity = ${AON_ROLE}. Required. Hostname fallback only when env unset
# (interactive use on un-onboarded boxes).
#
# Usage:
#   bash scripts/worktree-claim.sh <slug>
#
# Prereqs:
#   - Card column=Backlog, no claimed_by, assignee in {<your-role>, any-worker}.
#   - Card exists in $TASK_DIR/<slug>.md.
set -euo pipefail

SLUG="${1:?usage: $0 <slug>}"
TASK_DIR="${AON_TASK_DIR:-.tasks}"

WORKER="${AON_ROLE:-$(hostname | tr '[:upper:]' '[:lower:]')}"
if [ -z "${AON_ROLE:-}" ]; then
  echo "warning: AON_ROLE unset — using hostname fallback '$WORKER'. Recommended: export AON_ROLE=<role> before launch." >&2
fi

# Discover the card from CWD's git toplevel (the ai-over-nats / task-board repo).
CARD_REPO="$(git rev-parse --show-toplevel)"
CARD="$CARD_REPO/$TASK_DIR/$SLUG.md"
[ -f "$CARD" ] || { echo "card not found: $CARD" >&2; exit 1; }

# repo: frontmatter selects which checkout the worktree branches off.
# Absent → single-repo mode (legacy): use CWD's repo.
REPO_FIELD=$(awk -F': *' '/^repo:/{print $2; exit}' "$CARD" | tr -d '[:space:]"' || true)
if [ -n "$REPO_FIELD" ]; then
  HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  REPO_ROOT="$(bash "$HARNESS_DIR/scripts/ensure-clone.sh" "$REPO_FIELD")"
else
  REPO_ROOT="$CARD_REPO"
fi

REPO_NAME="$(basename "$REPO_ROOT")"
WORKTREES_ROOT="${AON_WORKTREES_DIR:-$(dirname "$REPO_ROOT")/${REPO_NAME}.worktrees}"
WORKTREE_DIR="$WORKTREES_ROOT/$WORKER/$SLUG"
BRANCH="$WORKER/$SLUG"

cd "$CARD_REPO"

git pull origin master --rebase --autostash 2>/dev/null || git pull origin main --rebase --autostash

ASSIGNEE=$(awk -F': *' '/^assignee:/{print $2; exit}' "$CARD" | tr -d '[:space:]')
COLUMN=$(awk -F': *' '/^column:/{print $2; exit}' "$CARD" | tr -d '[:space:]')
CLAIMED=$(awk -F': *' '/^claimed_by:/{print $2; exit}' "$CARD" | tr -d '[:space:]' || true)

case "$ASSIGNEE" in
  "$WORKER"|any-worker) : ;;
  *) echo "card is assigned to '$ASSIGNEE', not '$WORKER' or any-worker. Refusing." >&2; exit 2 ;;
esac
[ "$COLUMN" = "Backlog" ] || { echo "card column is '$COLUMN', not Backlog. Refusing." >&2; exit 2; }
[ -z "$CLAIMED" ] || { echo "card already claimed_by='$CLAIMED'. Refusing." >&2; exit 2; }

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 - "$CARD" "$WORKER" "$TS" <<'PY'
import re, sys
path, worker, ts = sys.argv[1:4]
src = open(path).read()
src = re.sub(r'(?m)^column:.*$', 'column: InProgress', src, count=1)
src = re.sub(r'(?m)^claimed_by:.*\n?', '', src)
src = re.sub(r'(?m)^claimed_at:.*\n?', '', src)
parts = src.split('---\n', 2)
parts[1] = parts[1].rstrip() + f'\nclaimed_by: {worker}\nclaimed_at: {ts}\n'
open(path, 'w').write('---\n'.join(parts))
PY
git add "$CARD"
git commit -m "claim: $SLUG" >/dev/null

PUSH_REF="$(git symbolic-ref --short HEAD)"
if ! git push origin "$PUSH_REF" 2>/tmp/wt-claim.err; then
  echo "── claim race lost on '$SLUG' ──" >&2
  cat /tmp/wt-claim.err >&2
  echo "Rolling back local commit and pulling fresh."
  git reset --hard HEAD^
  git pull origin "$PUSH_REF" --rebase --autostash
  exit 3
fi

mkdir -p "$WORKTREES_ROOT/$WORKER"
cd "$REPO_ROOT"
# Refresh from local host mount before branching (multi-repo path) or from origin (legacy).
if git remote | grep -qx host; then
  git fetch host --prune --quiet 2>/dev/null || true
  BASE_REF="host/master"
  git rev-parse --verify --quiet "$BASE_REF" >/dev/null || BASE_REF="host/main"
else
  git fetch origin --prune --quiet 2>/dev/null || true
  BASE_REF="origin/master"
  git rev-parse --verify --quiet "$BASE_REF" >/dev/null || BASE_REF="origin/main"
fi
if git worktree list | grep -q " $WORKTREE_DIR "; then
  echo "worktree already exists at $WORKTREE_DIR — reusing"
else
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "$BASE_REF"
fi

echo
echo "✓ claimed $SLUG"
echo "✓ worktree:  $WORKTREE_DIR"
echo "✓ branch:    $BRANCH"
echo "✓ identity:  $WORKER"
echo
echo "Next step (run in the worktree):"
echo "  cd $WORKTREE_DIR"
