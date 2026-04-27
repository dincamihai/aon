#!/usr/bin/env bash
# apparmor-watcher.sh — invoked by the macOS LaunchAgent
# `com.team-alpha.apparmor-watcher` whenever an entry in
# $TEAM_ALPHA_REPOS_ROOT (default $HOME/Repos) is added or removed.
#
# Runs `team-alpha-apparmor sync --reload`. ThrottleInterval=10 in the
# plist throttles relaunches; this script itself adds a fast no-op
# guard so back-to-back fires within 5s collapse.

set -euo pipefail

# LaunchAgents start with a minimal PATH. Add Homebrew + standard locations
# so colima, git, and the rest of the toolchain resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LOCK="/tmp/team-alpha-apparmor-watcher.lock"
LOG="${HOME}/.team-alpha/apparmor-watcher.log"
mkdir -p "$(dirname "$LOG")"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Debounce: skip if the lock was touched in the last 5 seconds.
if [[ -f "$LOCK" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if [[ "$age" -lt 5 ]]; then
    echo "$(now)  skip  age=${age}s" >> "$LOG"
    exit 0
  fi
fi
touch "$LOCK"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TA_BIN="$(cd -- "$SCRIPT_DIR/../../bin" && pwd)/team-alpha-apparmor"

if [[ ! -x "$TA_BIN" ]]; then
  echo "$(now)  error  team-alpha-apparmor not executable at $TA_BIN" >> "$LOG"
  exit 1
fi

echo "$(now)  fire  running team-alpha-apparmor sync --reload" >> "$LOG"
if "$TA_BIN" sync --reload >> "$LOG" 2>&1; then
  echo "$(now)  ok" >> "$LOG"
else
  rc=$?
  echo "$(now)  fail  rc=$rc" >> "$LOG"
  exit "$rc"
fi
