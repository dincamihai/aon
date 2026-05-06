#!/usr/bin/env bash
# Bootstrap a host-side tmux session that:
#   - runs `aon security watch` in pane 0 (operator, host creds)
#   - opens one pane per role, each ssh'ing into the VM and attaching
#     (via dtach) to that role's persistent claude session
#
# Team-agnostic. Team is the cwd if it contains aon.toml, else the
# directory passed as -d/--team-dir. Roles default to the roster from
# aon.toml; pass explicit role names to override.
#
# Agents in the VM keep running when you detach the host tmux. Re-attach
# anytime — dtach reconnects you to the live claude. No tmux-in-tmux.
#
# Usage:
#   bash aon-tmux.sh                       # cwd as team, all roles
#   bash aon-tmux.sh rona tim              # cwd, only these roles
#   bash aon-tmux.sh -d ~/Repos/workers    # explicit team dir, all roles
#   bash aon-tmux.sh -d ~/Repos/workers rona tim
#
# Env:
#   AON_TMUX_SESSION   default = team name (basename of team dir)
#   AON_COLIMA_PROFILE default "aon"

set -eu

TEAM_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--team-dir) TEAM_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ -z "$TEAM_DIR" ] && TEAM_DIR="$PWD"
TEAM_DIR="$(cd "$TEAM_DIR" && pwd)"
[ -f "$TEAM_DIR/aon.toml" ] \
  || { echo "no aon.toml at $TEAM_DIR — pass -d <team-dir>" >&2; exit 1; }

# Pull roster from aon.toml if no explicit roles given.
roles_from_toml() {
  awk '/^\[\[roles/{r=1;next} /^\[/{r=0;next}
       r && /^[[:space:]]*name[[:space:]]*=/{
         gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); print
       }' "$TEAM_DIR/aon.toml"
}

if [ $# -gt 0 ]; then
  ROLES=( "$@" )
else
  mapfile -t ROLES < <(roles_from_toml)
fi
[ "${#ROLES[@]}" -gt 0 ] || { echo "no roles in $TEAM_DIR/aon.toml roster" >&2; exit 1; }

TEAM_NAME="$(basename "$TEAM_DIR")"
SESS="${AON_TMUX_SESSION:-$TEAM_NAME}"
PROFILE="${AON_COLIMA_PROFILE:-aon}"

command -v tmux   >/dev/null || { echo "tmux missing on host"; exit 1; }
command -v colima >/dev/null || { echo "colima missing on host"; exit 1; }
command -v aon    >/dev/null || { echo "aon missing on host"; exit 1; }

SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

# 1. Ensure each role exists in VM (worker UID + worktree + creds), then
#    ensure its claude is running under dtach.
for r in "${ROLES[@]}"; do
  # Auto-create worker if missing. Idempotent.
  colima ssh --profile "$PROFILE" -- sudo bash -c "
    id ta-worker-$r >/dev/null 2>&1 ||
      bash $SCRIPT_DIR/add-worker.sh $r >&2
  "
  # Push role creds into VM if missing. Per-role only — never sysadmin.
  colima ssh --profile "$PROFILE" -- bash -c "
    test -r /etc/team-alpha/creds/$r.creds
  " 2>/dev/null || {
    src="$HOME/.aon/teams/$TEAM_NAME/creds/$r.creds"
    if [ -r "$src" ]; then
      cat "$src" | colima ssh --profile "$PROFILE" -- sudo bash -c "
        install -d -m 0755 -o root -g root /etc/team-alpha/creds
        install -m 0600 -o root -g root /dev/stdin /etc/team-alpha/creds/$r.creds
        setfacl -m u:ta-worker-$r:r /etc/team-alpha/creds/$r.creds
      "
    else
      echo "warn: no host creds for $r at $src — skipping" >&2
      continue
    fi
  }
  colima ssh --profile "$PROFILE" -- sudo bash \
    "$SCRIPT_DIR/start-agent-in-vm.sh" "$r" >/dev/null
done

# 2. tmux session — operator pane + one pane per role
if tmux has-session -t "$SESS" 2>/dev/null; then
  echo "tmux session '$SESS' already exists. Attaching."
  tmux attach -t "$SESS"
  exit 0
fi

tmux new-session -d -s "$SESS" -n ops -c "$TEAM_DIR"
tmux send-keys -t "$SESS:ops" \
  "aon security watch" C-m

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
