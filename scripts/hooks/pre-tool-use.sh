#!/usr/bin/env bash
# Claude Code PreToolUse hook entry point. Delegates to the
# command safety gate. Lives here (not in scripts/security/) so the
# install.sh wiring stays consistent with the rest of the hooks.
set -u

ENGINE_DIR="${AON_ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
exec bash "$ENGINE_DIR/scripts/security/cmd-gate.sh" "$@"
