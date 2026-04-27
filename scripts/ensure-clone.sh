#!/usr/bin/env bash
# ensure-clone.sh — ensure a per-worker writable local clone of <repo> exists.
#
# Idempotent. Hardlinks objects from the read-only host mount via
# `git clone --shared`. After cloning, points `origin` at the same GitHub URL
# as the host repo (so PRs push the right place) and rewires a `host` remote
# pointing at the local mount (so `git fetch host master` is cheap).
#
# Layout (inside sandbox VM):
#
#   $TEAM_ALPHA_REPOS_ROOT/<repo>/.git              # read-only host mount, origin
#                                ▲
#                                │ git clone --shared
#                                ▼
#   $TEAM_ALPHA_WORKER_HOME/<repo>/.git             # rw local clone for this worker
#
# Usage:
#   bash scripts/ensure-clone.sh <repo>
# Prints the resolved local clone path on stdout.
#
# Env:
#   TEAM_ALPHA_REPOS_ROOT  host repo mount root         default: /Users/$USER/Repos
#                                                       (Linux: /home/$USER/Repos)
#   TEAM_ALPHA_WORKER_HOME where local clones live      default: /work/workers/$TEAM_ALPHA_ROLE
#                                                       (fallback: $HOME/work)

set -euo pipefail

REPO="${1:?usage: $0 <repo>}"

# Default repos root: try /etc/team-alpha/env, then scan /Users/*/Repos
# (macOS host mount in sandbox VM) and /home/*/Repos (Linux host).
# Inside the sandbox the host UID does NOT match the worker UID, so $USER
# is unreliable — scan for any user dir containing a Repos/ tree.
if [[ -z "${TEAM_ALPHA_REPOS_ROOT:-}" && -r /etc/team-alpha/env ]]; then
  # shellcheck disable=SC1091
  . /etc/team-alpha/env
  TEAM_ALPHA_REPOS_ROOT="${TEAM_ALPHA_REPOS_ROOT:-${TA_PROJECT:-}}"
fi
if [[ -z "${TEAM_ALPHA_REPOS_ROOT:-}" ]]; then
  for cand in /Users/*/Repos /home/*/Repos; do
    [[ -d "$cand" ]] && { TEAM_ALPHA_REPOS_ROOT="$cand"; break; }
  done
fi

ORIGIN="$TEAM_ALPHA_REPOS_ROOT/$REPO"
[[ -d "$ORIGIN/.git" ]] || { echo "ensure-clone: $ORIGIN is not a git repo" >&2; exit 1; }

if [[ -z "${TEAM_ALPHA_WORKER_HOME:-}" ]]; then
  if [[ -n "${TEAM_ALPHA_ROLE:-}" && -d "/work/workers/$TEAM_ALPHA_ROLE" ]]; then
    TEAM_ALPHA_WORKER_HOME="/work/workers/$TEAM_ALPHA_ROLE"
  else
    TEAM_ALPHA_WORKER_HOME="$HOME/work"
  fi
fi
DEST="$TEAM_ALPHA_WORKER_HOME/$REPO"

if [[ ! -d "$DEST/.git" ]]; then
  mkdir -p "$(dirname "$DEST")"
  git clone --shared "$ORIGIN" "$DEST" >&2
  # Disable auto-gc — preserves --shared hardlinks.
  git -C "$DEST" config gc.auto 0

  # Rewire remotes:
  #   origin → GitHub URL inherited from the host repo (so push works)
  #   host   → local file mount (cheap fetches)
  HOST_GH="$(git -C "$ORIGIN" remote get-url origin 2>/dev/null || true)"
  git -C "$DEST" remote rename origin host 2>/dev/null || true
  if [[ -n "$HOST_GH" ]]; then
    git -C "$DEST" remote add origin "$HOST_GH"
  fi
fi

# Refresh from local host mount on every call. Cheap on hardlinks.
git -C "$DEST" fetch host --prune --quiet 2>/dev/null || true

echo "$DEST"
