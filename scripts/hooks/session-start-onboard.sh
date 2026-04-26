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

# Build per-subject Monitor blocks. ONE Monitor call per subject —
# `nats sub` comma-list parsing is unreliable across CLI versions (some
# split, some treat whole string as one literal subject = no matches).
# Membrain pattern: separate Monitor per subject.
case "$HOOK_ROLE" in
  maya)  SUBJECTS=("a2a.>" "agents.maya.inbox" "agents.*.events" "broadcast.>" "state.alert.>") ;;
  *)     SUBJECTS=("a2a.$HOOK_ROLE.tasks.>" "agents.$HOOK_ROLE.inbox" "broadcast.>") ;;
esac

MON_BLOCKS=""
for subj in "${SUBJECTS[@]}"; do
  short="$(printf '%s' "$subj" | tr -c '[:alnum:]' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  cmd="nats --server $HOOK_NATS_URL --user $HOOK_ROLE --password \"\$(cat $HOOK_CREDS)\" sub '$subj' 2>&1"
  MON_BLOCKS+="
  description: \"team-alpha $HOOK_ROLE $subj\"
  command: $cmd
  persistent: true
  timeout_ms: 3600000
"
done

CTX="team-alpha session start — role=$HOOK_ROLE host=$HOST.

Substrate is live. Handshake published, KV load=active.

ACTION REQUIRED — invoke the Monitor tool ONCE PER BLOCK below (do
NOT collapse into one call — \`nats sub\` comma-list parsing is
unreliable). Each Monitor delivers events for one subject pattern
as notifications.
$MON_BLOCKS
After all Monitors are running you have full realtime coverage.
Acknowledge new A2A task notifications by calling \`a2a_inbox()\`
once, then complete via \`a2a_update_status(task_id, 'completed',
artifact={...})\`. Do NOT poll \`a2a_inbox()\` or \`recent_events\`
in a loop — events push, you don't pull.

Audit-replay via session-start-catch-up.sh covers what you missed
since last cursor (already injected as separate context block).

Role brief is in your CLAUDE.md (auto-loaded). For full rules read
\`scripts/agent-prompts/$HOOK_ROLE.md\`. For substrate model read
\`MODEL.md\`."

jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
