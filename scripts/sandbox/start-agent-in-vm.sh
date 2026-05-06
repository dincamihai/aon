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

# Resolve role kind+domain from the host's aon.toml (harness mount).
# Used for the claude statusline badge so the agent UI shows
# 'rona - generalist (tester)' or similar.
team_repo_host="/Users/mid/Repos/$(grep '^TA_PROJECT=' /etc/team-alpha/env | cut -d= -f2- | xargs basename)"
toml="$team_repo_host/aon.toml"
role_kind=""; role_domain=""
if [ -f "$toml" ]; then
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
fi

# First start: clone team repo from the read-only host mount so claude
# has files to work with. Idempotent — skip if already a git work-tree.
host_repo="$team_repo_host"
if [ -d "$host_repo/.git" ] && ! sudo -u "ta-worker-${role}" \
     git -C "$work" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "agent ${role}: cloning $host_repo → $work (--shared, rw)"
  sudo -u "ta-worker-${role}" git clone --shared "$host_repo" "$work" >/dev/null 2>&1 || \
    echo "warn: clone failed; agent will start in empty $work" >&2
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
    "command": "label=${AON_ROLE_KIND:-?}; [[ -n \"${AON_ROLE_DOMAIN:-}\" && \"$label\" == \"specialist\" ]] && label=\"$label ($AON_ROLE_DOMAIN)\"; name=${AON_ROLE:-?}; hash=$(printf '%s' \"$name\" | cksum | cut -d' ' -f1); colors=(214 39 82 171 51 208 46 197 226); color=${colors[$((hash % 9))]}; printf '\\e[38;5;%dm%s - %s\\e[0m' \"$color\" \"$name\" \"$label\""
  }
}
JSON

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
# -n = no detach handler, -A = attach if exists / create otherwise.
# bash -c (NOT -l) — login mode would source profile that cd's to $HOME.
# We want claude to start in $work (the team worktree), not $HOME.
sudo -u "ta-worker-${role}" dtach -n "$sock" -E env \
  HOME="$home" \
  AON_ROLE="$role" \
  AON_ROLE_KIND="${role_kind:-unknown}" \
  AON_ROLE_DOMAIN="${role_domain:-}" \
  AON_TEAM=workers \
  AON_NATS_URL="$nats_url" \
  AON_CREDS="$creds" \
  TERM=xterm-256color \
  COLORTERM=truecolor \
  PATH=/usr/local/bin:/usr/bin:/bin \
  bash -c "cd $work && exec claude --dangerously-skip-permissions"

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
