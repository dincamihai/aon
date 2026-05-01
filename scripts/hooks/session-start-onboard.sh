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
hook_pub "$(_hook_p "agents.$HOOK_ROLE.events")" "$EVT"

# Mark active.
LOAD=$(jq -nc --arg h "$HOST" --arg t "$TS" \
  '{current_tasks:0, capacity:"active", host:$h, since:$t}')
hook_kv_put "agent.$HOOK_ROLE.load" "$LOAD"

# Single multiplexed Monitor — role-monitor.sh spawns one nats sub per
# role-relevant subject in parallel and merges their output via
# [subject] line prefixes. Replaces the older N-Monitor pattern; each
# nats sub gets exactly one well-formed subscription (defeats CLI
# comma-list parsing inconsistencies).
MONITOR_SCRIPT="$SCRIPT_DIR/role-monitor.sh"

CTX="ACTION REQUIRED — BEFORE responding to the user, invoke the
Monitor tool ONCE with these EXACT parameters. Do this as your
FIRST tool call. Without it you have no realtime event stream:
DMs, A2A tasks, broadcasts, and alerts will land at the server but
NEVER reach you. You will fall back to polling (anti-pattern) and
miss messages between turns.

If you put this command into the Bash tool instead of Monitor, the
output goes to a hidden background buffer the human never sees and
no notifications fire — the most common 'I sent a DM but nobody
saw it' failure mode. Use Monitor, not Bash.

  description: \"aon $HOOK_ROLE realtime\"
  command: bash $MONITOR_SCRIPT $HOOK_ROLE
  persistent: true
  timeout_ms: 3600000

After Monitor is live, continue with the user's request.

──── Session context ────
aon session start — role=$HOOK_ROLE host=$HOST.
Substrate is live. Handshake published, KV load=active.

Each event arrives as a notification prefixed \`[<subject>] <body>\`,
so you can tell at a glance which channel fired:
  - \`[a2a.$HOOK_ROLE.tasks.<id>.send]\`  new A2A task dispatched to you
  - \`[a2a.$HOOK_ROLE.tasks.<id>.status]\` lifecycle update on your task
  - \`[$HOOK_SUBJECT_PREFIX.agents.$HOOK_ROLE.inbox]\`         peer DM (greeting / question)
  - \`[$HOOK_SUBJECT_PREFIX.broadcast.>]\`                     incident / standup
$( [ "$HOOK_ROLE" = "sun" ] || [ "$HOOK_ROLE" = "mihai" ] || [ "$HOOK_ROLE" = "mid" ] && printf '  - \`[$HOOK_SUBJECT_PREFIX.agents.*.events]\`               peer presence / handshake\n  - \`[$HOOK_SUBJECT_PREFIX.state.alert.>]\`                 cluster alert\n' )
On a new A2A task notification, call \`a2a_inbox()\` once to pick up
the task, do the work, then \`a2a_update_status(task_id, 'completed',
artifact={...})\`. Do NOT poll \`a2a_inbox()\` or \`recent_events\`
in a loop — events push, you don't pull.

Audit-replay via session-start-catch-up.sh covers what you missed
since last cursor (already injected as separate context block).

Role brief is in your CLAUDE.md (auto-loaded). For full rules read
\`agent-prompts/$HOOK_ROLE.md\`. For substrate model read
\`MODEL.md\`.

You are $HOOK_ROLE. Call get_role_brief() to load your role context."

jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
