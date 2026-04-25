#!/usr/bin/env bash
# One-shot agent onboarding for team-alpha.
#
# Usage:
#   bash scripts/onboard.sh <role>
# where <role> ∈ {maya, raj, lin, sam, diego, priya}.
#
# Required env (set in launching shell):
#   TEAM_ALPHA_ROLE        must equal arg <role>
#   TEAM_ALPHA_NATS_URL    e.g. nats://nats.team-alpha.corp:4222
#   TEAM_ALPHA_CREDS       path to gitignored password file (chmod 600)

set -euo pipefail

ROLE="${1:-}"
VALID_ROLES="maya raj lin sam diego priya"

case " $VALID_ROLES " in
  *" $ROLE "*) ;;
  *) echo "usage: $0 <maya|raj|lin|sam|diego|priya>" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NATS_BIN="${NATS_BIN:-nats}"
command -v "$NATS_BIN" >/dev/null 2>&1 || {
  echo "ERROR: nats CLI not found on PATH (brew install nats-io/nats-tools/nats)" >&2
  exit 1
}

echo "── 1/6 validate env ──"
: "${TEAM_ALPHA_ROLE:?TEAM_ALPHA_ROLE not set in launching shell}"
: "${TEAM_ALPHA_NATS_URL:?TEAM_ALPHA_NATS_URL not set}"
: "${TEAM_ALPHA_CREDS:?TEAM_ALPHA_CREDS not set}"
if [ "$TEAM_ALPHA_ROLE" != "$ROLE" ]; then
  echo "ERROR: arg role=$ROLE but \$TEAM_ALPHA_ROLE=$TEAM_ALPHA_ROLE — refusing." >&2
  exit 2
fi
if [ ! -r "$TEAM_ALPHA_CREDS" ]; then
  echo "ERROR: creds file $TEAM_ALPHA_CREDS not readable" >&2
  exit 2
fi
PASS="$(tr -d '[:space:]' < "$TEAM_ALPHA_CREDS")"
if [ -z "$PASS" ]; then
  echo "ERROR: creds file $TEAM_ALPHA_CREDS empty" >&2
  exit 2
fi
echo "  ✓ role=$ROLE url=$TEAM_ALPHA_NATS_URL creds=$TEAM_ALPHA_CREDS"

# nats CLI invocation as this role.
nats_role() {
  "$NATS_BIN" --server "$TEAM_ALPHA_NATS_URL" --user "$ROLE" --password "$PASS" "$@"
}

echo "── 2/6 discover bus ──"
# Use rtt (no $SYS perms needed) — `server check connection` requires sysadmin.
if ! nats_role rtt >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: cannot reach NATS at $TEAM_ALPHA_NATS_URL as $ROLE.
  - on company VPN? try: ping $(echo "$TEAM_ALPHA_NATS_URL" | sed -E 's#^.*//([^:]+).*#\1#')
  - password correct? regenerate from secret manager.
  - operator's NATS host running? see docs/onboarding-per-role.md §0.
EOF
  exit 1
fi
echo "  ✓ NATS reachable + auth OK"

echo "── 3/6 post handshake ──"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(hostname)"
EVT=$(printf '{"type":"handshake","role":"%s","host":"%s","timestamp":"%s"}' "$ROLE" "$HOST" "$TS")
nats_role pub "agents.$ROLE.events" "$EVT" >/dev/null
echo "  ✓ handshake published to agents.$ROLE.events"

echo "── 4/6 seed load state ──"
LOAD_JSON='{"current_tasks":0,"capacity":"active","host":"'"$HOST"'","since":"'"$TS"'"}'
echo -n "$LOAD_JSON" | nats_role kv put team-state "agent.$ROLE.load" >/dev/null
echo "  ✓ team-state.agent.$ROLE.load = active"

echo "── 5/6 role prompt ──"
PROMPT="$REPO_ROOT/scripts/agent-prompts/$ROLE.md"
COMMON="$REPO_ROOT/scripts/agent-prompts/_common.md"
if [ -f "$PROMPT" ]; then
  echo "─── BEGIN PROMPT ($PROMPT) ───"
  [ -f "$COMMON" ] && cat "$COMMON" && echo
  cat "$PROMPT"
  echo "─── END PROMPT ───"
else
  echo "  ⚠ $PROMPT not found yet (card 50). Skipping prompt refresh."
fi

echo "── 6/6 monitors to start in this Claude session ──"
print_monitor() { printf '  %s\n  cmd: %s\n\n' "$1" "$2"; }

NATS_BASE="nats --server \"\$TEAM_ALPHA_NATS_URL\" --user \"$ROLE\" --password \"\$(cat \$TEAM_ALPHA_CREDS)\""

print_monitor "inbox (DMs)"             "$NATS_BASE sub agents.$ROLE.inbox"
print_monitor "broadcast"               "$NATS_BASE sub 'broadcast.>'"

case "$ROLE" in
  maya)
    print_monitor "all agent events"    "$NATS_BASE sub 'agents.*.events'"
    print_monitor "team state mirror"   "$NATS_BASE sub 'state.>'"
    ;;
  raj)
    print_monitor "all task pending"    "$NATS_BASE sub 'board.tasks.*.pending'"
    print_monitor "all learning pending" "$NATS_BASE sub 'board.learning.*.pending'"
    print_monitor "mentoring offers"    "$NATS_BASE sub 'board.learning.*.mentoring'"
    ;;
  lin)
    print_monitor "python tasks"        "$NATS_BASE sub 'board.tasks.python.pending'"
    print_monitor "ui tasks"            "$NATS_BASE sub 'board.tasks.ui.pending'"
    print_monitor "go tasks"            "$NATS_BASE sub 'board.tasks.go.pending'"
    print_monitor "go learning track"   "$NATS_BASE sub 'board.learning.go.>'"
    ;;
  sam)
    print_monitor "ui tasks (main)"     "$NATS_BASE sub 'board.tasks.ui.pending'"
    print_monitor "python learning"     "$NATS_BASE sub 'board.learning.python.pending'"
    print_monitor "go learning"         "$NATS_BASE sub 'board.learning.go.pending'"
    print_monitor "python mentors"      "$NATS_BASE sub 'board.learning.python.mentoring'"
    print_monitor "go mentors"          "$NATS_BASE sub 'board.learning.go.mentoring'"
    ;;
  diego)
    print_monitor "go tasks (main)"     "$NATS_BASE sub 'board.tasks.go.pending'"
    print_monitor "terraform learning"  "$NATS_BASE sub 'board.learning.terraform.>'"
    print_monitor "aws learning"        "$NATS_BASE sub 'board.learning.aws.>'"
    ;;
  priya)
    print_monitor "terraform tasks"     "$NATS_BASE sub 'board.tasks.terraform.pending'"
    print_monitor "aws tasks"           "$NATS_BASE sub 'board.tasks.aws.pending'"
    print_monitor "python learning"     "$NATS_BASE sub 'board.learning.python.>'"
    ;;
esac

echo "✓ Onboarded as $ROLE on $HOST. Start the monitors above as Monitor tool"
echo "  invocations in your Claude session, then stand by for events."
