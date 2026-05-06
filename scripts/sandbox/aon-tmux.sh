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

# Optional explicit agent list: [team] tmux_roles = ["a", "b", ...]
tmux_roles_from_toml() {
  awk '/^\[team\]/{r=1;next} /^\[/{r=0;next}
       r && /^[[:space:]]*tmux_roles[[:space:]]*=/{
         gsub(/^.*\[/, ""); gsub(/\].*$/, "")
         n = split($0, a, /[", \t]+/)
         for (i = 1; i <= n; i++) if (length(a[i]) > 0) print a[i]
       }' "$TEAM_DIR/aon.toml"
}

# Optional layout: [team] pane_layout = "left2-right3" | "tiled" (default)
pane_layout_from_toml() {
  awk '/^\[team\]/{r=1;next} /^\[/{r=0;next}
       r && /^[[:space:]]*pane_layout[[:space:]]*=/{
         gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); print; exit
       }' "$TEAM_DIR/aon.toml"
}

if [ $# -gt 0 ]; then
  ROLES=( "$@" )
else
  mapfile -t _tmux_roles < <(tmux_roles_from_toml)
  if [ "${#_tmux_roles[@]}" -gt 0 ]; then
    ROLES=( "${_tmux_roles[@]}" )
  else
    mapfile -t ROLES < <(roles_from_toml)
  fi
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
# Clear stale ssh control socket. Derive path from the rendered config
# (ControlPath line) so we don't reach into colima's internal dir layout.
_ssh_sock="$(awk '/^[[:space:]]*ControlPath[[:space:]]/{print $2; exit}' "$SSH_CONF" 2>/dev/null)"
[ -n "$_ssh_sock" ] && rm -f "$_ssh_sock" 2>/dev/null || true
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

# Validate ta-claude-auth credentials are fresh before pushing to workers.
# Exits with error + instructions if expired — better to fail before
# killing existing sessions than to start agents that immediately 401.
check_claude_auth() {
  [ "${AON_SHARE_CLAUDE_AUTH:-1}" = "1" ] || return 0
  local result
  result=$(ssh -F "$SSH_CONF" -o ControlPath=none "$SSH_HOST" \
    sudo python3 -c "
import json, time, sys
path='/var/lib/ta-claude-auth/.claude/.credentials.json'
try:
    d=json.load(open(path))
except: sys.exit(2)
exp=d.get('claudeAiOauth',{}).get('expiresAt',0)
ts=exp/1000 if exp>1e10 else exp
sys.exit(0 if ts>time.time() else 1)
" 2>/dev/null; echo $?)
  case "$result" in
    0) return 0 ;;
    2) echo "aon-tmux: no ta-claude-auth credentials — run: aon admin claude-login" >&2; exit 1 ;;
    *) echo "aon-tmux: ta-claude-auth token expired — run: aon admin claude-login" >&2; exit 1 ;;
  esac
}

# Share VM-side claude OAuth across roles. Always overwrites — ta-claude-auth
# is the single source of truth. check_claude_auth() ensures it's fresh first.
# Set AON_SHARE_CLAUDE_AUTH=0 to disable entirely.
share_claude_auth() {
  local role="$1"
  [ "${AON_SHARE_CLAUDE_AUTH:-1}" = "1" ] || return 0
  ssh -F "$SSH_CONF" -o ControlPath=none "$SSH_HOST" sudo bash -s "$role" <<'REMOTE' 2>/dev/null || \
    echo "warn: claude auth share failed for $role" >&2
set -eu
role="$1"
src_home="/var/lib/ta-claude-auth"
src_creds="$src_home/.claude/.credentials.json"
src_meta="$src_home/.claude.json"
dst_home="/var/lib/team-alpha/workers/$role"
[ -r "$src_creds" ] || { echo "no $src_creds" >&2; exit 1; }
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

# 1. Validate claude auth before touching anything, then ensure each role
#    exists in VM (worker UID + worktree + creds) and its claude is running.
check_claude_auth
for r in "${ROLES[@]}"; do
  share_claude_auth "$r"
  share_slack_config "$r"
  # Auto-create worker if missing. Idempotent.
  colima ssh --profile "$PROFILE" -- sudo bash -c "
    id ta-worker-$r >/dev/null 2>&1 ||
      bash $SCRIPT_DIR/add-worker.sh $r >&2
  "
  # Push role creds into VM if missing. Per-role only — never sysadmin.
  # Note: setfacl runs inside the VM (via colima ssh) where the `acl`
  # package is installed. It does NOT run on the macOS host.
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

# Window 1: team panes.
# Preserve TERM through sudo so claude's TUI keeps colors. -E preserves
# the env; we also explicitly pass TERM in case sudoers strips it.
attach_cmd() {
  local role="$1"
  echo "ssh -F $SSH_CONF -t $SSH_HOST 'TERM=\"\$TERM\" sudo -E -u ta-worker-$role env TERM=\"\$TERM\" dtach -a /tmp/aon-$role.sock'"
}

PANE_LAYOUT="$(pane_layout_from_toml)"
PANE_LAYOUT="${PANE_LAYOUT:-tiled}"

if [ "$PANE_LAYOUT" = "left2-right3" ] && [ "${#ROLES[@]}" -eq 5 ]; then
  # Layout:  left col → ROLES[0] top, ROLES[1] bottom
  #          right col → ROLES[2] top, ROLES[3] mid, ROLES[4] bottom
  # Use pane IDs (#{pane_id} = %N) — immune to pane-base-index.
  left_top="${ROLES[0]}"  left_bot="${ROLES[1]}"
  right_top="${ROLES[2]}" right_mid="${ROLES[3]}" right_bot="${ROLES[4]}"

  p_lt=$(tmux new-session -d -s "$SESS" -n team -c "$TEAM_DIR" \
    -P -F '#{pane_id}' "$(attach_cmd "$left_top")")
  tmux select-pane -t "$p_lt" -T "$left_top" 2>/dev/null || true

  # Full-height right column: horizontal split of left pane.
  p_rt=$(tmux split-window -h -t "$p_lt" -P -F '#{pane_id}' "$(attach_cmd "$right_top")")
  tmux select-pane -t "$p_rt" -T "$right_top" 2>/dev/null || true

  # Split right col down twice → three equal right panes.
  p_rm=$(tmux split-window -v -t "$p_rt" -P -F '#{pane_id}' "$(attach_cmd "$right_mid")")
  tmux select-pane -t "$p_rm" -T "$right_mid" 2>/dev/null || true

  p_rb=$(tmux split-window -v -t "$p_rm" -P -F '#{pane_id}' "$(attach_cmd "$right_bot")")
  tmux select-pane -t "$p_rb" -T "$right_bot" 2>/dev/null || true

  # Split left col down → two equal left panes.
  p_lb=$(tmux split-window -v -t "$p_lt" -P -F '#{pane_id}' "$(attach_cmd "$left_bot")")
  tmux select-pane -t "$p_lb" -T "$left_bot" 2>/dev/null || true
else
  first="${ROLES[0]}"
  rest=( "${ROLES[@]:1}" )

  p=$(tmux new-session -d -s "$SESS" -n team -c "$TEAM_DIR" \
    -P -F '#{pane_id}' "$(attach_cmd "$first")")
  tmux select-pane -t "$p" -T "$first" 2>/dev/null || true

  for r in "${rest[@]}"; do
    tmux split-window -t "$SESS:team" "$(attach_cmd "$r")"
    tmux select-pane -T "$r" 2>/dev/null || true
    tmux select-layout -t "$SESS:team" tiled >/dev/null
  done
  tmux select-layout -t "$SESS:team" tiled >/dev/null
fi

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
