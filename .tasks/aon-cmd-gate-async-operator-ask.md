---
column: In Progress
priority: high
parent: aon-cmd-gate-ollama-classifier
order: 1110
---

# operator-ask: async human approval (no timeout)

Replace `nats req` with deterministic-reply-subject pattern. Operator must be able to approve hours later.

## Requirements

### 1. Protocol: deterministic reply subject

Keep ADR design — do NOT use `nats req` (ephemeral inbox):

- Request: `evt.coord-in.gate-request.<role>.<req_id>`
- Reply: `evt.coord-out.gate-reply.<role>.<req_id>`
- Gate `sub --count=1` on reply subject (background, no timeout)
- Gate `pub` request subject
- `wait $sub_pid` — blocks until reply arrives, however long

### 2. No timeout

- GATE_ASK_TIMEOUT = 0 means forever
- No default 60s cap
- `wait` on sub PID, not sleep-poll loop

### 3. No race condition

Sub registers before pub on same NATS connection. No `sleep 0.2`.
Use sub PID existence or brief reliable wait, not arbitrary sleep.

### 4. Cleanup

- EXIT trap kills sub PID + removes reply tmpfile
- Deterministic tmpfile path: `/tmp/gate-reply.<role>.<req_id>`

### 5. ACL grants

- Keep `evt.coord-out.gate-reply.@ROLE@.>` in sub allow (needed for deterministic reply)
- Keep `evt.coord-in.gate-request.@ROLE@.>` in pub allow

### 6. Audit

- Log `req_id → reply subject` mapping before pub
- Log decision + operator identity when reply arrives

## Files to change

- `scripts/security/operator-ask.sh` — rewrite sub+pub+wait pattern
- `bin/aon-security-watch` — keep existing `REPLY_PREFIX` (no header parsing)
- `bin/aon` — `security approve/deny` keeps publishing to deterministic subject

## Rejection criteria

- Uses `nats req` → reject (ephemeral inbox breaks async workflow)
- Has hard-coded timeout → reject (must be 0 = forever or configurable)
- Uses `sleep` for sub registration → reject (use sub PID existence check)
- TUI parses `Reply-To` header → reject (use deterministic subject)
