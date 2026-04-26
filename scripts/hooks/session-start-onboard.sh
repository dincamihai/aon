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

# Compose subject set for the realtime Monitor.
# Workers also include a2a.<role>.tasks.> for direct dispatch events;
# maya includes broad a2a.> + agents.*.events for team-wide visibility.
case "$HOOK_ROLE" in
  maya)  MON_SUBJECTS="a2a.>,agents.maya.inbox,agents.*.events,broadcast.>,state.alert.>" ;;
  *)     MON_SUBJECTS="a2a.$HOOK_ROLE.tasks.>,agents.$HOOK_ROLE.inbox,broadcast.>" ;;
esac
MON_DESC="team-alpha $HOOK_ROLE realtime"
MON_CMD="nats --server $HOOK_NATS_URL --user $HOOK_ROLE --password \"\$(cat $HOOK_CREDS)\" sub '$MON_SUBJECTS' 2>&1"

CTX="team-alpha session start — role=$HOOK_ROLE host=$HOST.

Substrate is live. Handshake published, KV load=active.

ACTION REQUIRED — invoke the Monitor tool RIGHT NOW with these EXACT
parameters. This is your realtime event stream. Without it you receive
no notifications and fall back to polling (anti-pattern).

  description: \"$MON_DESC\"
  command: $MON_CMD
  persistent: true
  timeout_ms: 3600000

Each new event arrives as a notification mid-session. Acknowledge new
A2A task notifications by calling \`a2a_inbox()\` once, then complete
via \`a2a_update_status(task_id, 'completed', artifact={...})\`. Do
NOT poll \`a2a_inbox()\` or \`recent_events\` in a loop — events
push, you don't pull.

Audit-replay via session-start-catch-up.sh covers what you missed
since last cursor (already injected as separate context block).

Role brief is in your CLAUDE.md (auto-loaded). For full rules read
\`scripts/agent-prompts/$HOOK_ROLE.md\`. For substrate model read
\`MODEL.md\`."

jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
