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
github_token="$(grep '^GITHUB_TOKEN=' /etc/team-alpha/env | cut -d= -f2-)"

[ -d "$work" ]   || { echo "no $work — run add-worker.sh first" >&2; exit 1; }

# Resolve harness dir once — used by both self-heal blocks below.
harness_dir="$(grep '^TA_HARNESS=' /etc/team-alpha/env | cut -d= -f2-)"

# Ensure aon-mcp Linux venv exists (idempotent self-heal for VMs upgraded
# in place). Canonical build lives in install-in-vm.sh; this block catches
# the case where install ran before mcp-server source was available.
# cards.py patch requires re-sync from host source.
if command -v uv >/dev/null 2>&1 && [ ! -x /usr/local/bin/aon-mcp ] && [ -n "$harness_dir" ]; then
  echo "aon-mcp: building Linux venv (one-time)"
  install -d -m 0755 /opt/aon-mcp /opt/aon-mcp/src
  cp -a "$harness_dir/mcp-server/." /opt/aon-mcp/src/
  for stale in /opt/aon-mcp/src/.venv /opt/aon-mcp/src/build /opt/aon-mcp/src/src/aon_mcp.egg-info; do
    [ -e "$stale" ] && find "$stale" -delete
  done
  uv venv /opt/aon-mcp/venv >/dev/null
  uv pip install --quiet --python /opt/aon-mcp/venv/bin/python /opt/aon-mcp/src >/dev/null
  ln -sf /opt/aon-mcp/venv/bin/aon-mcp /usr/local/bin/aon-mcp
fi
# Ensure board-tui Linux venv exists (idempotent self-heal for upgraded VMs).
board_tui_src="${BOARD_TUI_SRC:-$(dirname "${harness_dir}")/board-tui}"
if command -v uv >/dev/null 2>&1 && [ ! -x /usr/local/bin/board-tui-mcp ] && [ -d "$board_tui_src" ]; then
  echo "board-tui: building Linux venv (one-time)"
  install -d -m 0755 /opt/board-tui /opt/board-tui/src
  cp -a "$board_tui_src/." /opt/board-tui/src/
  for stale in /opt/board-tui/src/.venv /opt/board-tui/src/build; do
    [ -e "$stale" ] && find "$stale" -delete
  done
  uv venv /opt/board-tui/venv >/dev/null
  uv pip install --quiet --python /opt/board-tui/venv/bin/python /opt/board-tui/src >/dev/null
  ln -sf /opt/board-tui/venv/bin/board-tui-mcp /usr/local/bin/board-tui-mcp
fi

sudo -u "ta-worker-${role}" test -r "$creds" \
  || { echo "ta-worker-${role} cannot read $creds — check ACL" >&2; exit 1; }

# Resolve role kind+domain from aon.toml. Used for the claude statusline
# badge so the agent UI shows 'rona - generalist (tester)' or similar.
# Search order: cloned worktree (always there once add-worker ran), then
# host mount fallback. host mount path varies (TA_PROJECT may be parent
# or team dir), so prefer worktree.
team_repo_host=""
ta_project="$(grep '^TA_PROJECT=' /etc/team-alpha/env | cut -d= -f2-)"
team_name="$(basename "$(dirname "$work")")"  # /work/<team>/<role> → <team>
for cand in \
    "$work/aon.toml" \
    "$ta_project/aon.toml" \
    "$ta_project/$team_name/aon.toml"
do
  [ -n "$cand" ] || continue
  if [ -f "$cand" ]; then toml="$cand"; team_repo_host="$(dirname "$cand")"; break; fi
done
toml="${toml:-}"
role_kind=""; role_domain=""; team_name_toml=""; kv_bucket=""
if [ -n "$toml" ] && [ -f "$toml" ]; then
  role_kind=$(awk -v r="$role" '
    /^\[\[roles/{n="";k="";d=""}
    /^[[:space:]]*name[[:space:]]*=/{ gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); n=$0 }
    /^[[:space:]]*kind[[:space:]]*=/{ gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); k=$0 }
    /^$/  { if (n==r) { print k; exit } }
    END   { if (n==r) print k }
  ' "$toml")
  role_domain=$(awk -v r="$role" '
    /^\[\[roles/{n="";d=""}
    /^[[:space:]]*name[[:space:]]*=/{ gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); n=$0 }
    /^[[:space:]]*domain[[:space:]]*=/{ gsub(/^[^"]*"/, ""); gsub(/".*$/, ""); d=$0 }
    /^$/  { if (n==r) { print d; exit } }
    END   { if (n==r) print d }
  ' "$toml")
  # Read team-level fields from [team] section
  team_name_toml=$(awk '
    /^\[team\]/{in_team=1; next} /^\[/{in_team=0}
    in_team && /^[[:space:]]*name[[:space:]]*=/{gsub(/^[^"]*"/,""); gsub(/".*$/,""); print; exit}
  ' "$toml")
  kv_bucket=$(awk '
    /^\[team\]/{in_team=1; next} /^\[/{in_team=0}
    in_team && /^[[:space:]]*kv_bucket[[:space:]]*=/{gsub(/^[^"]*"/,""); gsub(/".*$/,""); print; exit}
  ' "$toml")
fi
# Fallbacks: team name from work dir, KV bucket from team name convention
team_name_toml="${team_name_toml:-$team_name}"
kv_bucket="${kv_bucket:-${team_name_toml%-aon}-state}"

# First start: clone team repo from the host mount so claude has files
# to work with. Idempotent — skip if already a git work-tree.
#
# git clone refuses non-empty target dirs. Prior runs may have left
# /.claude/ etc. behind, so clone into a temp dir then move contents in.
host_repo="$team_repo_host"
if [ -n "$host_repo" ] && [ -d "$host_repo/.git" ] && ! sudo -u "ta-worker-${role}" \
     git -C "$work" rev-parse --show-toplevel >/dev/null 2>&1; then
  tmp_clone="/tmp/aon-clone-${role}.$$"
  rm -rf "$tmp_clone"
  echo "agent ${role}: cloning $host_repo → $work"
  # safe.directory='*' bypasses git's dubious-ownership check — host
  # mount UID won't match worker UID inside the VM.
  # Persist safe.directory='*' in worker's gitconfig — source-repo
  # access during clone forks git-upload-pack which doesn't inherit
  # GIT_CONFIG_* env reliably across all forks.
  sudo -u "ta-worker-${role}" git config --global --add safe.directory '*' || true
  if sudo -u "ta-worker-${role}" git clone --shared "$host_repo" "$tmp_clone"; then
    # Move .git + tracked files into $work without disturbing pre-existing
    # .claude/settings etc. cp -a preserves modes/owners.
    sudo -u "ta-worker-${role}" bash -c "
      shopt -s dotglob
      cp -a $tmp_clone/. $work/
    "
    sudo rm -rf "$tmp_clone"
  else
    sudo rm -rf "$tmp_clone" 2>/dev/null || true
    echo "warn: clone failed; agent will start in empty $work" >&2
  fi
fi

# Provision .claude/settings.local.json in the worktree so claude
# renders a per-role statusline badge inside the agent. Reads
# pre-set AON_ROLE/AON_ROLE_KIND/AON_ROLE_DOMAIN env (no
# 'aon resolve-env' dance — registry lookups don't apply in the VM).
sudo -u "ta-worker-${role}" mkdir -p "$work/.claude"
cat <<'JSON' | sudo -u "ta-worker-${role}" tee "$work/.claude/settings.local.json" >/dev/null
{
  "model": "sonnet",
  "statusLine": {
    "type": "command",
    "command": "bash -c 'label=${AON_ROLE_KIND:-?}; if [[ -n \"${AON_ROLE_DOMAIN:-}\" && \"$label\" == \"specialist\" ]]; then label=\"$label ($AON_ROLE_DOMAIN)\"; fi; name=${AON_ROLE:-?}; hash=$(printf %s \"$name\" | cksum | cut -d\" \" -f1); colors=(214 39 82 171 51 208 46 197 226); color=${colors[$((hash % 9))]}; printf \"\\e[38;5;%dm%s - %s\\e[0m\" \"$color\" \"$name\" \"$label\"'"
  }
}
JSON

# Provision per-role .mcp.json. All roles get aon + aon-board.
# Slack is opt-in: only the role(s) listed in AON_SLACK_ROLES (env or
# default 'sun') get it. Slack server runs via uvx from the host-mounted
# slack-mcp repo (sibling of harness under TA_REPOS / TA_PROJECT parent).
slack_mcp_src="$(dirname "${harness_dir}")/slack-mcp"
aon_board_dir="$(grep '^TA_AON_BOARD=' /etc/team-alpha/env | cut -d= -f2-)"
# Fallback: use TA_PROJECT parent + aon-board convention
aon_board_dir="${aon_board_dir:-$(dirname "${ta_project}")/aon-board}"

SLACK_ROLES="${AON_SLACK_ROLES:-sun}"
mcp_extra=""
for sr in $SLACK_ROLES; do
  if [ "$sr" = "$role" ]; then
    mcp_extra=",
    \"slack\": {
      \"type\": \"stdio\",
      \"command\": \"uvx\",
      \"args\": [\"--from\", \"${slack_mcp_src}\", \"slack-mcp\"]
    }"
    # slack-mcp reads ~/.config/slack-mcp/config.toml. Pushed into role's
    # home by aon-tmux share_slack_config() on each --restart.
    break
  fi
done
cat <<JSON | sudo -u "ta-worker-${role}" tee "$work/.mcp.json" >/dev/null
{
  "mcpServers": {
    "aon": {
      "type": "stdio",
      "command": "aon",
      "args": ["mcp-server", "aon"]
    },
    "aon-board": {
      "type": "stdio",
      "command": "aon",
      "args": ["mcp-server", "board"],
      "env": { "BOARD_TASKS_DIR": "${aon_board_dir}" }
    }${mcp_extra}
  }
}
JSON

# Provision per-role ~/.claude/settings.json enabling opt-in Claude Code plugins.
# AON_ATLASSIAN_ROLES (default: sun) — enables Atlassian plugin (Jira/Confluence).
# Credentials (OAuth tokens) are already shared via share_claude_auth → .credentials.json.
sudo -u "ta-worker-${role}" install -d -m 0700 "$home/.claude"
ATLASSIAN_ROLES="${AON_ATLASSIAN_ROLES:-sun}"
atlassian_enabled=false
for ar in $ATLASSIAN_ROLES; do
  [ "$ar" = "$role" ] && atlassian_enabled=true && break
done
settings_file="$home/.claude/settings.json"
existing="{}"
if sudo -u "ta-worker-${role}" test -r "$settings_file" 2>/dev/null; then
  existing="$(sudo -u "ta-worker-${role}" cat "$settings_file")"
fi
new_settings="$(printf '%s' "$existing" | jq \
  --argjson atlassian "$atlassian_enabled" \
  '.enabledPlugins["atlassian@claude-plugins-official"] = $atlassian')"
printf '%s\n' "$new_settings" | sudo -u "ta-worker-${role}" tee "$settings_file" >/dev/null
echo "agent ${role}: settings.json written (atlassian plugin: $atlassian_enabled)"

# Already running with a live process behind the socket? Skip.
# Otherwise nuke the orphan socket so dtach -n can re-create it.
if [ -S "$sock" ]; then
  if pgrep -u "ta-worker-${role}" -f "dtach -n $sock" >/dev/null; then
    echo "agent ${role}: already running, socket=$sock"
    exit 0
  fi
  echo "agent ${role}: orphan socket at $sock — removing"
  rm -f "$sock"
fi

echo "agent ${role}: starting under dtach (sock=$sock, cwd=$work)"
# Build monitor init prompt — mirrors `aon launch` so agents arm their
# role-monitor at session start (persistent Monitor tool, not Bash).
_monitor_init="invoke Monitor tool with persistent=true and timeout_ms=3600000: bash ${harness_dir}/scripts/hooks/role-monitor.sh ${role}"

# -n = no detach handler, -A = attach if exists / create otherwise.
# bash -c (NOT -l) — login mode would source profile that cd's to $HOME.
# We want claude to start in $work (the team worktree), not $HOME.
sudo -u "ta-worker-${role}" dtach -n "$sock" -E env \
  HOME="$home" \
  AON_ROLE="$role" \
  AON_ROLE_KIND="${role_kind:-unknown}" \
  AON_ROLE_DOMAIN="${role_domain:-}" \
  AON_TEAM="${team_name_toml}" \
  AON_KV_BUCKET="${kv_bucket}" \
  AON_NATS_URL="$nats_url" \
  AON_CREDS="$creds" \
  ${github_token:+GITHUB_TOKEN="$github_token"} \
  AON_MCP_BIN=/usr/local/bin/aon-mcp \
  BOARD_TUI_MCP_BIN=/usr/local/bin/board-tui-mcp \
  AON_AGENTS_DIR="$work/agents" \
  TERM=xterm-256color \
  COLORTERM=truecolor \
  PATH=/usr/local/bin:/usr/bin:/bin \
  bash -c "cd $(printf '%q' "$work") && exec claude --dangerously-skip-permissions $(printf '%q' "$_monitor_init")"

# Verify the dtach process is actually alive and serving the socket.
# If claude crashed at startup (e.g., bad auth, missing TTY) dtach -n
# leaves an orphan socket that subsequent dtach -a calls will fail on.
sleep 0.5
if ! pgrep -u "ta-worker-${role}" -f "dtach -n $sock" >/dev/null; then
  echo "agent ${role}: ERROR — dtach exited at startup. Check claude flags + auth." >&2
  rm -f "$sock"
  exit 1
fi
echo "agent ${role}: started OK, socket=$sock"
echo "agent ${role}: started. Attach: dtach -a $sock"
