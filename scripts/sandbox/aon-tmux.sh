#!/usr/bin/env bash
# Bootstrap a host-side tmux session that:
#   - runs `aon security watch` in pane 0 (operator, host creds)
#   - opens one pane per role, each ssh'ing into the VM and attaching
#     (via dtach) to that role's persistent claude session
#
# Agents in the VM keep running when you detach the host tmux. Re-attach
# anytime — dtach reconnects you to the live claude. No tmux-in-tmux.
#
# Usage:
#   bash aon-tmux.sh [<role> ...]
#   defaults to: rona tim sun
#
# Env:
#   AON_TMUX_SESSION   default "aon"
#   AON_COLIMA_PROFILE default "aon"

set -eu

ROLES=( "${@:-rona tim sun}" )
SESS="${AON_TMUX_SESSION:-aon}"
PROFILE="${AON_COLIMA_PROFILE:-aon}"

command -v tmux   >/dev/null || { echo "tmux missing on host"; exit 1; }
command -v colima >/dev/null || { echo "colima missing on host"; exit 1; }
command -v aon    >/dev/null || { echo "aon missing on host"; exit 1; }

# 1. Ensure each role's claude is running in VM under dtach
for r in "${ROLES[@]}"; do
  colima ssh --profile "$PROFILE" -- sudo bash \
    "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/start-agent-in-vm.sh" "$r" \
    >/dev/null
done

# 2. tmux session — operator pane + one pane per role
if tmux has-session -t "$SESS" 2>/dev/null; then
  echo "tmux session '$SESS' already exists. Attaching."
  tmux attach -t "$SESS"
  exit 0
fi

tmux new-session -d -s "$SESS" -n ops
tmux send-keys -t "$SESS:ops" \
  "cd ~/Repos/workers && aon security watch" C-m

for r in "${ROLES[@]}"; do
  tmux new-window -t "$SESS" -n "$r"
  # -t : -- TTY allocation (claude needs PTY)
  # dtach -a : attach to existing socket (created by start-agent-in-vm.sh)
  tmux send-keys -t "$SESS:$r" \
    "colima ssh --profile $PROFILE -t -- sudo -u ta-worker-$r dtach -a /tmp/aon-$r.sock" C-m
done

tmux new-window -t "$SESS" -n logs
tmux send-keys -t "$SESS:logs" \
  "colima ssh --profile $PROFILE -t -- sudo journalctl -fu 'team-alpha-*' --since now" C-m

echo "Started tmux session '$SESS'. Attaching."
tmux attach -t "$SESS"
