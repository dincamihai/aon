#!/usr/bin/env bash
# Wire aon hooks into .claude/settings.json.
# Default target: ~/.claude/settings.json (global, aon.toml guard activates per-dir).
# Legacy: use 'install-project' to write into the current repo's .claude/settings.json.
# Idempotent. Supports check and uninstall.
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"
PROJECT_SETTINGS="$REPO_ROOT/.claude/settings.json"

cmd="${1:-global}"

# Default target follows command.
case "$cmd" in
  global|check-global|uninstall-global) SETTINGS="$GLOBAL_SETTINGS"; mkdir -p "$HOME/.claude" ;;
  *) SETTINGS="$PROJECT_SETTINGS"; mkdir -p "$REPO_ROOT/.claude" ;;
esac

# Absolute-path hooks block — used by engine's own .claude/settings.json
# and as input to cmd_admin_hooks_install's portable rewrite.
build_hooks_block() {
  cat <<JSON
{
  "SessionStart": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/session-start-onboard.sh" },
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/session-start-catch-up.sh" }
    ]}
  ],
  "Stop": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/stop.sh" }
    ]}
  ],
  "PostToolUse": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/post-tool-use.sh" },
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/post-tool-context-refresh.sh" },
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/post-tool-status-ping.sh" }
    ]}
  ],
  "UserPromptSubmit": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/user-prompt-submit.sh" }
    ]}
  ],
  "PreCompact": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/pre-compact.sh" }
    ]}
  ],
  "PreToolUse": [
    { "matcher": "Bash", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/pre-tool-use.sh" }
    ]},
    { "matcher": "Read|Write|Edit|MultiEdit", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/pre-tool-use.sh" }
    ]}
  ],
  "SessionEnd": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $REPO_ROOT/scripts/hooks/session-end-goodbye.sh" }
    ]}
  ]
}
JSON
}

# Portable hooks block — uses `aon hook X` form for ~/.claude/settings.json.
# Idempotent: running global twice produces identical output (jq merge is
# last-write-wins on same keys, so re-running overwrites with same value).
build_portable_hooks_block() {
  cat <<'JSON'
{
  "SessionStart": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook session-start-onboard" },
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook session-start-catch-up" }
    ]}
  ],
  "Stop": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook stop" }
    ]}
  ],
  "PostToolUse": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook post-tool-use" },
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook post-tool-context-refresh" },
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook post-tool-status-ping" }
    ]}
  ],
  "UserPromptSubmit": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook user-prompt-submit" }
    ]}
  ],
  "PreCompact": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook pre-compact" }
    ]}
  ],
  "PreToolUse": [
    { "matcher": "Bash", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook pre-tool-use" }
    ]},
    { "matcher": "Read|Write|Edit|MultiEdit", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook pre-tool-use" }
    ]}
  ],
  "SessionEnd": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env) && aon hook session-end-goodbye" }
    ]}
  ]
}
JSON
}

case "$cmd" in
  check)
    if [ ! -f "$SETTINGS" ]; then
      echo "✗ no settings file at $SETTINGS"
      exit 1
    fi
    if jq -e '.hooks.SessionStart and .hooks.Stop and .hooks.PostToolUse and .hooks.PreCompact and .hooks.SessionEnd and .hooks.UserPromptSubmit and .hooks.PreToolUse' "$SETTINGS" >/dev/null 2>&1; then
      echo "✓ hooks present in $SETTINGS"
      exit 0
    else
      echo "✗ hooks missing or partial in $SETTINGS"
      exit 1
    fi
    ;;
  uninstall)
    if [ -f "$SETTINGS" ]; then
      jq 'del(.hooks.SessionStart) | del(.hooks.Stop)
          | del(.hooks.PostToolUse) | del(.hooks.PreCompact)
          | del(.hooks.SessionEnd) | del(.hooks.UserPromptSubmit)
          | del(.hooks.PreToolUse)
          | if .hooks == {} then del(.hooks) else . end' \
        "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
      echo "✓ hooks removed from $SETTINGS"
    else
      echo "no settings file — nothing to remove"
    fi
    exit 0
    ;;
  global|"")
    HOOKS_JSON="$(build_portable_hooks_block)"
    if [ -f "$SETTINGS" ]; then
      jq --argjson hooks "$HOOKS_JSON" '.hooks = ((.hooks // {}) + $hooks)' \
        "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    else
      jq --argjson hooks "$HOOKS_JSON" -n '{hooks: $hooks}' > "$SETTINGS"
    fi
    echo "✓ hooks installed into $SETTINGS (global)"
    echo "  aon.toml guard — only active in aon-configured directories"
    exit 0
    ;;
  install|"")
    HOOKS_JSON="$(build_hooks_block)"
    if [ -f "$SETTINGS" ]; then
      jq --argjson hooks "$HOOKS_JSON" '.hooks = ((.hooks // {}) + $hooks)' \
        "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    else
      jq --argjson hooks "$HOOKS_JSON" -n '{hooks: $hooks}' > "$SETTINGS"
    fi
    echo "✓ hooks installed into $SETTINGS"
    echo "  SessionStart: onboard + catch-up"
    echo "  Stop:         flip load=idle, emit session_end"
    exit 0
    ;;
  install-project)
    # Legacy: write into the current repo's .claude/settings.json instead of global.
    SETTINGS="$PROJECT_SETTINGS"
    mkdir -p "$REPO_ROOT/.claude"
    HOOKS_JSON="$(build_hooks_block)"
    if [ -f "$SETTINGS" ]; then
      jq --argjson hooks "$HOOKS_JSON" '.hooks = ((.hooks // {}) + $hooks)' \
        "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    else
      jq --argjson hooks "$HOOKS_JSON" -n '{hooks: $hooks}' > "$SETTINGS"
    fi
    echo "✓ hooks installed into $SETTINGS (project-level)"
    exit 0
    ;;
  role-dirs)
    # Stamp .claude/settings.json into each ~/team-alpha/<role>/ so
    # cold claude sessions launched from the role dir get the same hooks.
    HOOKS_JSON="$(build_hooks_block)"
    for role in maya raj lin sam diego priya; do
      role_dir="$HOME/team-alpha/$role"
      [ -d "$role_dir" ] || { echo "skip $role (no $role_dir)"; continue; }
      mkdir -p "$role_dir/.claude"
      role_settings="$role_dir/.claude/settings.json"
      if [ -f "$role_settings" ]; then
        jq --argjson hooks "$HOOKS_JSON" '.hooks = ($hooks + (.hooks // {}))' \
          "$role_settings" > "$role_settings.tmp" && mv "$role_settings.tmp" "$role_settings"
      else
        jq --argjson hooks "$HOOKS_JSON" -n '{hooks: $hooks}' > "$role_settings"
      fi
      echo "✓ stamped $role_settings"
    done
    exit 0
    ;;
  *)
    echo "usage: $0 [global|install-project|check|uninstall|role-dirs]" >&2
    exit 2
    ;;
esac
