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

# Default target follows command. check/uninstall default to global (same target
# as the global install) so bare `install.sh check` reflects actual installed state.
case "$cmd" in
  global|check|uninstall|check-global|uninstall-global) SETTINGS="$GLOBAL_SETTINGS"; mkdir -p "$HOME/.claude" ;;
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
# Commands guard on AON_ROLE after eval so a broken resolve-env doesn't
# silently skip hooks while also not masking the failure.
build_portable_hooks_block() {
  cat <<'JSON'
{
  "SessionStart": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook session-start-onboard" },
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook session-start-catch-up" }
    ]}
  ],
  "Stop": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook stop" }
    ]}
  ],
  "PostToolUse": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook post-tool-use" },
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook post-tool-context-refresh" },
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook post-tool-status-ping" }
    ]}
  ],
  "UserPromptSubmit": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook user-prompt-submit" }
    ]}
  ],
  "PreCompact": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook pre-compact" }
    ]}
  ],
  "PreToolUse": [
    { "matcher": "Bash", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook pre-tool-use" }
    ]},
    { "matcher": "Read|Write|Edit|MultiEdit", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook pre-tool-use" }
    ]}
  ],
  "SessionEnd": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "eval $(aon resolve-env 2>/dev/null) && [ -n \"${AON_ROLE:-}\" ] && aon hook session-end-goodbye" }
    ]}
  ]
}
JSON
}

# Merge $HOOKS_JSON into $SETTINGS without clobbering other plugins' hook arrays.
# For each event key, strips existing aon-hook entries (identified by "aon hook"
# in the command) then appends the new ones — idempotent and non-destructive.
merge_hooks() {
  local settings="$1" hooks_json="$2"
  if [ -f "$settings" ]; then
    jq --argjson h "$hooks_json" '
      reduce ($h | to_entries[]) as $e (
        .;
        .hooks[$e.key] = (
          ((.hooks[$e.key] // []) | map(select(.hooks | any(.command | test("aon hook")) | not))) +
          $e.value
        )
      )
    ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
  else
    jq --argjson h "$hooks_json" -n '{hooks: ($h)}' > "$settings"
  fi
}

do_project_install() {
  local target="${1:-$PROJECT_SETTINGS}"
  mkdir -p "$(dirname "$target")"
  HOOKS_JSON="$(build_hooks_block)"
  merge_hooks "$target" "$HOOKS_JSON"
  echo "✓ hooks installed into $target"
  echo "  SessionStart: onboard + catch-up"
  echo "  Stop:         flip load=idle, emit session_end"
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
      # Strip only aon hook entries from each event array; delete the key only
      # if the array becomes empty — preserves other plugins' hooks on shared keys.
      jq '
        if .hooks then
          .hooks |= with_entries(
            .value |= map(select(.hooks | any(.command | test("aon hook")) | not))
          ) |
          .hooks |= with_entries(select(.value | length > 0)) |
          if .hooks == {} then del(.hooks) else . end
        else . end
      ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
      echo "✓ aon hooks removed from $SETTINGS"
    else
      echo "no settings file — nothing to remove"
    fi
    exit 0
    ;;
  global)
    HOOKS_JSON="$(build_portable_hooks_block)"
    merge_hooks "$SETTINGS" "$HOOKS_JSON"
    echo "✓ hooks installed into $SETTINGS (global)"
    echo "  aon.toml guard — only active in aon-configured directories"
    exit 0
    ;;
  install)
    do_project_install "$PROJECT_SETTINGS"
    exit 0
    ;;
  install-project)
    # Legacy alias for install — writes into the current repo's .claude/settings.json.
    do_project_install "$PROJECT_SETTINGS"
    echo "  (project-level)"
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
    echo "usage: $0 [global|install|install-project|check|uninstall|role-dirs]" >&2
    exit 2
    ;;
esac
