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
RESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--team-dir) TEAM_DIR="$2"; shift 2 ;;
    --restart) RESTART=1; shift ;;
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

# colima ssh has no -t (no PTY allocation). For commands that need a
# PTY (interactive dtach -a, journalctl follow), shell out via plain
# ssh using colima's ssh-config. Render to a stable file once. Also
# clear any stale ssh control socket so reconnects work.
SSH_CONF="$HOME/.aon/colima-${PROFILE}.ssh-config"
mkdir -p "$(dirname "$SSH_CONF")"
colima ssh-config --profile "$PROFILE" >"$SSH_CONF"
SSH_HOST="colima-${PROFILE}"
rm -f "$HOME/.colima/_lima/colima-${PROFILE}/ssh.sock" 2>/dev/null
ssh_pty() { ssh -F "$SSH_CONF" -t "$SSH_HOST" "$@"; }

# --restart: kill all dtach sessions in VM + tear down host tmux session
# so the next loop creates fresh dtach sessions with current env (TERM,
# AON_ROLE_KIND, latest .claude.json, etc.). Idempotent.
if [ "$RESTART" = "1" ]; then
  echo "aon-tmux: --restart — killing all aon-* dtach sessions in VM + tmux session '$SESS' on host"
  ssh -F "$SSH_CONF" -o ControlPath=none "$SSH_HOST" \
    'sudo pkill -9 -f "dtach -n /tmp/aon-" 2>/dev/null; sudo rm -f /tmp/aon-*.sock' \
    >/dev/null 2>&1 || true
  if tmux has-session -t "$SESS" 2>/dev/null; then
    tmux kill-session -t "$SESS" >/dev/null 2>&1 || true
  fi
fi

# Share VM-side claude OAuth across roles. Source: a dedicated VM user
# `ta-claude-auth` that the operator logged into once via
# `aon admin claude-login`. We copy its ~/.claude.json + ~/.claude/
# .credentials.json into each role's home before launching the agent.
#
# Enabled by default when /var/lib/ta-claude-auth/.claude/.credentials.json
# exists in the VM. Set AON_SHARE_CLAUDE_AUTH=0 to disable.
#
# No host → VM copy. macOS Keychain not touched.
share_claude_auth() {
  local role="$1"
  [ "${AON_SHARE_CLAUDE_AUTH:-1}" = "1" ] || return 0
  ssh -F "$SSH_CONF" -o ControlPath=none "$SSH_HOST" sudo bash -s "$role" <<'REMOTE' 2>/dev/null || \
    echo "warn: claude auth share failed for $role (run 'aon admin claude-login' first?)" >&2
set -eu
role="$1"
src_home="/var/lib/ta-claude-auth"
src_creds="$src_home/.claude/.credentials.json"
src_meta="$src_home/.claude.json"
dst_home="/var/lib/team-alpha/workers/$role"
[ -r "$src_creds" ] || { echo "no $src_creds — login missing" >&2; exit 1; }
# Account metadata: sanitize host-specific fields (none here, but keep
# del(.projects) so per-role state stays clean across reuses).
if [ -r "$src_meta" ]; then
  tmp="$(mktemp)"
  jq '.installMethod = "global-npm" | del(.projects)' "$src_meta" > "$tmp"
  install -m 0600 -o "ta-worker-$role" -g team-alpha "$tmp" "$dst_home/.claude.json"
  rm -f "$tmp"
fi
install -d -m 0700 -o "ta-worker-$role" -g team-alpha "$dst_home/.claude"
install -m 0600 -o "ta-worker-$role" -g team-alpha "$src_creds" "$dst_home/.claude/.credentials.json"
REMOTE
}

# Push host's slack-mcp config (~/.config/slack-mcp/config.toml) into
# the per-role VM home so slack-mcp can authenticate. Only invoked for
# roles listed in AON_SLACK_ROLES (default: sun).
share_slack_config() {
  local role="$1"
  local roles="${AON_SLACK_ROLES:-sun}"
  local match=0; for sr in $roles; do [ "$sr" = "$role" ] && match=1; done
  [ "$match" = "1" ] || return 0
  local src="$HOME/.config/slack-mcp/config.toml"
  [ -r "$src" ] || { echo "warn: $src missing — slack MCP for $role won't auth" >&2; return 0; }
  scp -F "$SSH_CONF" -q "$src" "$SSH_HOST:/tmp/aon-${role}-slack.toml"
  ssh -F "$SSH_CONF" "$SSH_HOST" sudo bash -c "'
    install -d -m 0700 -o ta-worker-$role -g team-alpha \
      /var/lib/team-alpha/workers/$role/.config/slack-mcp
    install -m 0600 -o ta-worker-$role -g team-alpha \
      /tmp/aon-${role}-slack.toml \
      /var/lib/team-alpha/workers/$role/.config/slack-mcp/config.toml
    rm -f /tmp/aon-${role}-slack.toml
  '"
}

# 1. Ensure each role exists in VM (worker UID + worktree + creds), then
#    ensure its claude is running under dtach.
for r in "${ROLES[@]}"; do
  share_claude_auth "$r"
  share_slack_config "$r"
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

# 2. tmux session — two windows:
#     window "team": tiled panes, one per role (the agents)
#     window "security": single pane running 'aon security watch'
if tmux has-session -t "$SESS" 2>/dev/null; then
  echo "tmux session '$SESS' already exists. Attaching."
  tmux attach -t "$SESS"
  exit 0
fi

# Window 1: team — first role takes the initial pane, rest are splits.
first="${ROLES[0]}"
rest=( "${ROLES[@]:1}" )
# Preserve TERM through sudo so claude's TUI keeps colors. -E preserves
# the env; we also explicitly pass TERM in case sudoers strips it.
attach_cmd() {
  local role="$1"
  echo "ssh -F $SSH_CONF -t $SSH_HOST 'TERM=\"\$TERM\" sudo -E -u ta-worker-$role env TERM=\"\$TERM\" dtach -a /tmp/aon-$role.sock'"
}

tmux new-session -d -s "$SESS" -n team -c "$TEAM_DIR" \
  "$(attach_cmd "$first")"
tmux select-pane -t "$SESS:team.0" -T "$first" 2>/dev/null || true

for r in "${rest[@]}"; do
  tmux split-window -t "$SESS:team" "$(attach_cmd "$r")"
  tmux select-pane -t "$SESS:team.+" -T "$r" 2>/dev/null || true
  tmux select-layout -t "$SESS:team" tiled >/dev/null
done
tmux select-layout -t "$SESS:team" tiled >/dev/null

# Window 2: security — operator's ask-watcher.
tmux new-window -t "$SESS" -n security -c "$TEAM_DIR"
tmux send-keys -t "$SESS:security" "aon security watch" C-m

# Pane titles in border.
tmux set -t "$SESS" -g pane-border-status top
tmux set -t "$SESS" -g pane-border-format "#{pane_index}: #{pane_title}"

# Land on the team window first.
tmux select-window -t "$SESS:team"

echo "Started tmux session '$SESS': window 'team' (${#ROLES[@]} role panes) + window 'security'."
tmux attach -t "$SESS"
