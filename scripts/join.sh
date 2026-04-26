#!/usr/bin/env bash
# Joiner-side onboarding for team-alpha.
#
# Usage:
#   bash scripts/join.sh <role> <work-repo>
#
# Stamps .claude/settings.json + .mcp.json into <work-repo>, saves
# the role password to ~/.team-alpha/<role>.password (chmod 600),
# and verifies a NATS handshake. After this script succeeds the
# joiner runs `cd <work-repo> && claude` to start their agent.
#
# Idempotent — safe to re-run after upgrades or to fix typos.
set -euo pipefail

ROLE="${1:-}"
WORK_REPO="${2:-}"

VALID_ROLES="maya raj lin sam diego priya"
case " $VALID_ROLES " in
  *" $ROLE "*) ;;
  *)
    cat >&2 <<EOF
usage: $0 <role> <work-repo>
  role        one of {maya, raj, lin, sam, diego, priya}
  work-repo   path to the code repo where you'll \`cd <repo> && claude\`
              (e.g. ~/Repos/saas)
EOF
    exit 2 ;;
esac

if [ -z "$WORK_REPO" ]; then
  echo "ERROR: <work-repo> required (e.g. ~/Repos/saas)" >&2
  exit 2
fi
WORK_REPO="$(cd "$WORK_REPO" 2>/dev/null && pwd)" || {
  echo "ERROR: <work-repo> '$2' is not a directory" >&2; exit 2; }
[ -d "$WORK_REPO/.git" ] || \
  echo "WARN: $WORK_REPO is not a git repo — continuing anyway." >&2

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── prereq checks ──
need() {
  command -v "$1" >/dev/null 2>&1 \
    || { echo "ERROR: $1 not on PATH ($2)" >&2; exit 1; }
}
need claude  "npm install -g @anthropic-ai/claude-code"
need nats    "brew install nats-io/nats-tools/nats"
need jq      "brew install jq"
need python3 "(should be present on macOS)"
need pipx    "brew install pipx && pipx ensurepath"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "WARN: \$ANTHROPIC_API_KEY not set in this shell." >&2
  echo "      Claude CLI will prompt you to log in interactively." >&2
fi

# ── creds ──
CREDS_DIR="$HOME/.team-alpha"
mkdir -p "$CREDS_DIR"
chmod 700 "$CREDS_DIR"
CREDS_FILE="$CREDS_DIR/$ROLE.password"

if [ -s "$CREDS_FILE" ]; then
  echo "▸ using existing creds: $CREDS_FILE"
else
  printf "Role password for %s: " "$ROLE"
  IFS= read -rs PASS
  echo
  if [ -z "$PASS" ]; then
    echo "ERROR: empty password" >&2; exit 2
  fi
  printf "%s" "$PASS" > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  unset PASS
  echo "▸ saved creds → $CREDS_FILE (chmod 600)"
fi

# ── NATS URL ──
DEFAULT_URL="${TEAM_ALPHA_NATS_URL:-wss://nats.example.com}"
printf "NATS URL [%s]: " "$DEFAULT_URL"
read -r NATS_URL
NATS_URL="${NATS_URL:-$DEFAULT_URL}"

# Persist for future shells.
ENV_FILE="$CREDS_DIR/$ROLE.env"
cat > "$ENV_FILE" <<EOF
# team-alpha env for $ROLE — source this in your shell rc:
#   echo 'source $ENV_FILE' >> ~/.zshrc
export TEAM_ALPHA_ROLE=$ROLE
export TEAM_ALPHA_NATS_URL=$NATS_URL
export TEAM_ALPHA_CREDS=$CREDS_FILE
EOF
chmod 600 "$ENV_FILE"
echo "▸ wrote env → $ENV_FILE"

# ── NATS handshake ──
PASS_NOSPACE=$(tr -d '[:space:]' < "$CREDS_FILE")
echo "▸ probing $NATS_URL as $ROLE …"
# Use `pub` to the role's own events subject — `nats rtt` and
# `server ping` both return 0 even on connection failure (CLI
# quirk). `pub` returns non-zero on dial / auth / ACL error.
# Every role has publish on agents.<role>.events.
if ! nats --server "$NATS_URL" --user "$ROLE" --password "$PASS_NOSPACE" --timeout 5s \
        pub "agents.$ROLE.events" '{"kind":"probe","ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' \
        >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: NATS handshake failed.
  url:  $NATS_URL
  user: $ROLE
  Common causes:
    - admin's cloudflared tunnel not running
    - wrong password (delete $CREDS_FILE and re-run)
    - wrong URL
  Ping admin in the backchannel.
EOF
  exit 1
fi
echo "▸ ✓ NATS reachable as $ROLE"

# ── stamp work repo ──
WR_CLAUDE="$WORK_REPO/.claude"
mkdir -p "$WR_CLAUDE"
SETTINGS="$WR_CLAUDE/settings.json"
MCP="$WORK_REPO/.mcp.json"

# venv path for team-alpha-mcp — built next to ai-over-nats checkout.
VENV_BIN="$REPO_ROOT/mcp-server/.venv/bin/team-alpha-mcp"
if [ ! -x "$VENV_BIN" ]; then
  echo "▸ installing team-alpha-mcp venv (one-time)"
  python3 -m venv "$REPO_ROOT/mcp-server/.venv"
  "$REPO_ROOT/mcp-server/.venv/bin/pip" install --quiet \
    --upgrade pip
  "$REPO_ROOT/mcp-server/.venv/bin/pip" install --quiet \
    "$REPO_ROOT/mcp-server"
fi
[ -x "$VENV_BIN" ] || { echo "ERROR: $VENV_BIN missing after install" >&2; exit 1; }

BOARD_BIN="${BOARD_TUI_MCP_BIN:-$(command -v board-tui-mcp || true)}"
if [ -z "$BOARD_BIN" ] || [ ! -x "$BOARD_BIN" ]; then
  echo "▸ installing board-tui via pipx (one-time)"
  pipx install --quiet git+https://github.com/dincamihai/board-tui.git \
    || { echo "ERROR: pipx install board-tui failed" >&2; exit 1; }
  BOARD_BIN="$(command -v board-tui-mcp || true)"
  if [ -z "$BOARD_BIN" ] || [ ! -x "$BOARD_BIN" ]; then
    echo "ERROR: board-tui-mcp not on PATH after install — check pipx ensurepath" >&2
    exit 1
  fi
fi
BOARD_TASKS_DIR="${TEAM_ALPHA_BOARD_DIR:-$HOME/team-alpha-board}"
mkdir -p "$BOARD_TASKS_DIR"

# .mcp.json — registers team-alpha + board MCPs scoped to this repo.
cat > "$MCP" <<EOF
{
  "mcpServers": {
    "team-alpha": {
      "type": "stdio",
      "command": "$VENV_BIN",
      "args": [],
      "env": {
        "TEAM_ALPHA_ROLE": "$ROLE",
        "TEAM_ALPHA_NATS_URL": "$NATS_URL",
        "TEAM_ALPHA_CREDS": "$CREDS_FILE"
      }
    },
    "team-alpha-board": {
      "type": "stdio",
      "command": "$BOARD_BIN",
      "args": [],
      "env": {
        "BOARD_TASKS_DIR": "$BOARD_TASKS_DIR"
      }
    }
  }
}
EOF
echo "▸ wrote $MCP"

# .claude/settings.json — install team-alpha hooks pointing at the
# ai-over-nats checkout so SessionStart / Stop / PostToolUse fire.
HOOK_INSTALL="$REPO_ROOT/scripts/hooks/install.sh"
if [ -r "$HOOK_INSTALL" ]; then
  # Run installer in ai-over-nats so it produces a fresh settings.json.
  ( cd "$REPO_ROOT" && bash "$HOOK_INSTALL" install >/dev/null )
  if [ -f "$REPO_ROOT/.claude/settings.json" ]; then
    # Bake env vars into each hook command so the work-repo's
    # claude session doesn't depend on the joiner sourcing
    # ~/.team-alpha/<role>.env first.
    ENV_PREFIX="env TEAM_ALPHA_ROLE=$ROLE TEAM_ALPHA_NATS_URL=$NATS_URL TEAM_ALPHA_CREDS=$CREDS_FILE"
    jq --arg pre "$ENV_PREFIX " '
      .hooks |= (
        with_entries(
          .value |= map(
            .hooks |= map(
              if .type == "command" and (.command | startswith($pre) | not)
              then .command = ($pre + .command)
              else .
              end
            )
          )
        )
      )
    ' "$REPO_ROOT/.claude/settings.json" > "$SETTINGS.tmp" \
      && mv "$SETTINGS.tmp" "$SETTINGS"
    echo "▸ installed hooks (env baked in) → $SETTINGS"
  fi
else
  echo "WARN: hook installer missing at $HOOK_INSTALL — skipping" >&2
fi

# ── role brief: symlink CLAUDE.md to the role brief, if not present ──
BRIEF_SRC="$REPO_ROOT/scripts/agent-prompts/$ROLE.md"
BRIEF_LINK="$WORK_REPO/CLAUDE.md"
if [ -f "$BRIEF_LINK" ] || [ -L "$BRIEF_LINK" ]; then
  echo "▸ keeping existing $BRIEF_LINK (not overwriting your work-repo CLAUDE.md)"
else
  ln -s "$BRIEF_SRC" "$BRIEF_LINK"
  echo "▸ symlinked $BRIEF_LINK → $BRIEF_SRC"
fi

cat <<EOF

✓ Setup complete.

Next:
  cd $WORK_REPO
  claude

Inside claude, your first turn will:
  - open a Monitor on your subscribed NATS subjects
  - publish a hello event on agents.$ROLE.events
  - load your role brief from $BRIEF_SRC

Watch live (separate terminal):
  nats --server $NATS_URL --user $ROLE --password \$(cat $CREDS_FILE) sub 'AUDIT.>'

Env file (source in shell rc for convenience):
  $ENV_FILE
EOF
