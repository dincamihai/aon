#!/usr/bin/env bash
# Wire team-alpha hooks into project-level .claude/settings.json.
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
    if jq -e '.hooks.SessionStart and .hooks.Stop' "$SETTINGS" >/dev/null 2>&1; then
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
      jq --argjson hooks "$HOOKS_JSON" '.hooks = ($hooks + (.hooks // {}))' \
        "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    else
      jq --argjson hooks "$HOOKS_JSON" -n '{hooks: $hooks}' > "$SETTINGS"
    fi
    echo "✓ hooks installed into $SETTINGS"
    echo "  SessionStart: onboard + catch-up"
    echo "  Stop:         flip load=idle, emit session_end"
    exit 0
    ;;
  *)
    echo "usage: $0 [install|check|uninstall]" >&2
    exit 2
    ;;
esac
