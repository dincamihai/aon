#!/usr/bin/env bash
# Stop hook — fires after every assistant turn (NOT per session).
# Side-effects must be turn-safe: no event spam, no duplicate state writes.
# Session-end semantics live in session-end-goodbye.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

TS="$(now_iso)"

# Bump cursor each turn so a session-restart catch-up doesn't replay
# events the agent already saw via the Monitor.
echo -n "$TS" > "$HOOK_CURSOR_FILE" 2>/dev/null || true

# Phase B: idle drill — Stop hook schema does NOT accept
# hookSpecificOutput.additionalContext (PostToolUse/UserPromptSubmit
# only). Marker stays in place; user-prompt-submit.sh injects the
# drill on the next operator turn instead. No-op here.
exit 0
