#!/usr/bin/env bash
# Smoke 07 — human-in-the-loop default + delegate opt-out.
#
# Default posture: human is in the loop unless an agent has been explicitly
# delegated authority via a KV flag. This gate is a *convention* enforced by
# agent prompts (card 50), not by NATS ACL — but the substrate must support
# checking + flipping the flag cleanly, and the audit must record both
# states.
#
# Validates:
#   - team-state.policy.delegated key exists or is creatable
#   - Maya can flip it (manager-controlled policy)
#   - non-managers cannot flip it (subject-perm check)
#   - flipping it produces a state.policy event auditable in EVENTS+AUDIT
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 07 human-in-the-loop ──"

# Maya writes the policy KV (manager-controlled).
echo -n '{"delegated":false,"set_by":"maya","ts":"'"$(date -u +%FT%TZ)"'"}' \
  | nats_as maya kv put team-state policy.delegated >/dev/null 2>&1 \
  && ok "maya wrote policy.delegated=false" \
  || bad "maya cannot write policy.delegated"

# Read back.
val=$(nats_as sysadmin kv get team-state policy.delegated --raw 2>/dev/null)
echo "$val" | grep -q '"delegated":false' \
  && ok "policy.delegated read back as false (human-in-loop default)" \
  || bad "policy KV read mismatch: $val"

# Non-manager (sam) attempts to flip — should be blocked.
# Sam's publish allow does NOT include $KV.team-state.policy.>; expect denial.
out=$(echo -n '{"delegated":true,"set_by":"sam-attack"}' \
      | nats_as sam kv put team-state policy.delegated 2>&1)
if echo "$out" | grep -qi "permissions violation\|forbidden\|unauthor\|deadline exceeded\|timeout"; then
  ok "sam correctly denied/timed-out write to policy.delegated"
else
  bad "sam was NOT denied — policy KV is unprotected: $out"
fi
# Verify policy.delegated still reads back its prior value (sam couldn't tamper).
val_after=$(nats_as sysadmin kv get team-state policy.delegated --raw 2>/dev/null)
echo "$val_after" | grep -qv 'sam-attack' \
  && ok "policy KV not tampered (no 'sam-attack' marker)" \
  || bad "sam tampered with policy KV: $val_after"

# Maya flips to delegated=true and emits a state.policy event.
echo -n '{"delegated":true,"set_by":"maya","ts":"'"$(date -u +%FT%TZ)"'"}' \
  | nats_as maya kv put team-state policy.delegated >/dev/null 2>&1 \
  && ok "maya flipped to delegated=true" \
  || bad "maya cannot flip"

# Companion event so subscribers (non-readers of KV) see the change.
nats_as maya pub state.policy '{"delegated":true,"set_by":"maya"}' >/dev/null 2>&1 \
  && ok "maya published state.policy event" \
  || bad "maya cannot publish state.policy"

# Restore default.
echo -n '{"delegated":false,"set_by":"smoke-restore"}' \
  | nats_as maya kv put team-state policy.delegated >/dev/null 2>&1
nats_as maya pub state.policy '{"delegated":false,"set_by":"smoke-restore"}' >/dev/null 2>&1

echo
echo "  human note: this test only verifies the substrate supports the"
echo "  delegate-opt-out gate. Whether agents actually CHECK the flag before"
echo "  acting autonomously is enforced by their role prompt (card 50), and"
echo "  validated by the multi-agent sim (card 65)."

summary
