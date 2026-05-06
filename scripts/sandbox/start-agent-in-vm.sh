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

# Already running? Skip.
if [ -S "$sock" ]; then
  echo "agent ${role}: already attached at $sock"
  exit 0
fi

echo "agent ${role}: starting under dtach (sock=$sock)"
# -n = no detach handler, -A = attach if exists / create otherwise
sudo -u "ta-worker-${role}" dtach -n "$sock" -E env \
  HOME="$home" \
  AON_ROLE="$role" \
  AON_TEAM=workers \
  AON_NATS_URL="$nats_url" \
  AON_CREDS="$creds" \
  PATH=/usr/local/bin:/usr/bin:/bin \
  bash -lc "cd $work && claude --dangerously-skip-permissions"
echo "agent ${role}: started. Attach: dtach -a $sock"
