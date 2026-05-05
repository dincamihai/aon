#!/usr/bin/env bash
# Wire aon hooks into project-level .claude/settings.json.
# Idempotent. Supports --check and --uninstall (no env required for those).
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="$REPO_ROOT/.claude/settings.json"
mkdir -p "$REPO_ROOT/.claude"

cmd="${1:-install}"

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
  install|"")
    HOOKS_JSON="$(build_hooks_block)"
    if [ -f "$SETTINGS" ]; then
      # Right side wins on key collision in jq's `+`. We want the freshly-
      # built $hooks (with the *current* REPO_ROOT) to win over any stale
      # entries left from a previous machine's install — otherwise hook
      # commands keep pointing at the original operator's clone path.
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
    echo "usage: $0 [install|check|uninstall|role-dirs]" >&2
    exit 2
    ;;
esac
