#!/usr/bin/env bash
# SessionStart hook — auto-handshake + inject Monitor instructions.
#
# Effects on first session start of any cycle:
#   1. Publish handshake event to agents.<role>.events
#   2. Update KV state.agent.<role>.load = active
#   3. Emit additionalContext telling the agent which Monitors to start
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

TS="$(now_iso)"
HOST="$(hostname)"

# Handshake.
EVT=$(jq -nc --arg r "$HOOK_ROLE" --arg h "$HOST" --arg t "$TS" \
  '{type:"handshake", role:$r, host:$h, timestamp:$t, message:"session start"}')
hook_pub "agents.$HOOK_ROLE.events" "$EVT"

# Mark active.
LOAD=$(jq -nc --arg h "$HOST" --arg t "$TS" \
  '{current_tasks:0, capacity:"active", host:$h, since:$t}')
hook_kv_put "agent.$HOOK_ROLE.load" "$LOAD"

# Build per-role Monitor command list.
MON_BLOCK=""
while IFS= read -r subj; do
  MON_BLOCK+="  - sub '$subj'
"
done < <(hook_role_subjects)

CTX="team-alpha session start — role=$HOOK_ROLE host=$HOST.

Substrate is live. Handshake published, KV load=active.

ACTION: start NATS Monitor tools NOW for these subjects (one per Monitor call,
persistent: true, timeout_ms: 3600000):

$MON_BLOCK
Each Monitor command shape:
  nats --server \$TEAM_ALPHA_NATS_URL --user $HOOK_ROLE \\
       --password \"\$(cat \$TEAM_ALPHA_CREDS)\" sub <subject>

Without these, you receive no real-time events. Audit-replay via session-start-
catch-up.sh covers what you missed since last cursor.

Read scripts/agent-prompts/$HOOK_ROLE.md for role rules + boundaries.
Read MODEL.md for the why."

jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
