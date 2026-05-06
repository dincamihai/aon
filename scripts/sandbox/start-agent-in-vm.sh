#!/usr/bin/env bash
# Run inside VM as root. Starts a single role's claude under dtach so it
# survives ssh drops. Idempotent: re-running while running is a no-op
# (dtach -A reuses existing socket).
#
# Usage:
#   sudo bash start-agent-in-vm.sh <role>

set -eu
role="${1:?usage: $0 <role>}"

sock="/tmp/aon-${role}.sock"
home="/var/lib/team-alpha/workers/${role}"
work="/work/workers/${role}"
creds="/etc/team-alpha/creds/${role}.creds"
nats_url="$(grep '^AON_NATS_URL=' /etc/team-alpha/env | cut -d= -f2-)"

[ -d "$work" ]   || { echo "no $work — run add-worker.sh first" >&2; exit 1; }
[ -r "$creds" ] && [ -O "$creds" ] || true   # readable check below
sudo -u "ta-worker-${role}" test -r "$creds" \
  || { echo "ta-worker-${role} cannot read $creds — check ACL" >&2; exit 1; }

# First start: clone team repo from the read-only host mount so claude
# has files to work with. Idempotent — skip if already a git work-tree.
team_name="$(grep '^TA_PROJECT=' /etc/team-alpha/env | cut -d= -f2- | xargs basename)"
host_repo="/Users/mid/Repos/${team_name}"
if [ -d "$host_repo/.git" ] && ! sudo -u "ta-worker-${role}" \
     git -C "$work" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "agent ${role}: cloning $host_repo → $work (--shared, rw)"
  sudo -u "ta-worker-${role}" git clone --shared "$host_repo" "$work" >/dev/null 2>&1 || \
    echo "warn: clone failed; agent will start in empty $work" >&2
fi

# Already running? Skip.
if [ -S "$sock" ]; then
  echo "agent ${role}: already attached at $sock"
  exit 0
fi

echo "agent ${role}: starting under dtach (sock=$sock, cwd=$work)"
# -n = no detach handler, -A = attach if exists / create otherwise.
# bash -c (NOT -l) — login mode would source profile that cd's to $HOME.
# We want claude to start in $work (the team worktree), not $HOME.
sudo -u "ta-worker-${role}" dtach -n "$sock" -E env \
  HOME="$home" \
  AON_ROLE="$role" \
  AON_TEAM=workers \
  AON_NATS_URL="$nats_url" \
  AON_CREDS="$creds" \
  TERM="${TERM:-xterm-256color}" \
  COLORTERM=truecolor \
  PATH=/usr/local/bin:/usr/bin:/bin \
  bash -c "cd $work && exec claude --dangerously-skip-permissions"
echo "agent ${role}: started. Attach: dtach -a $sock"
