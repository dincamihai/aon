---
column: Backlog
created: 2026-05-14
order: 168
---

# A2A per-skill server-side ACL bouncer

Current ACL enforcement is per-role at the NATS subject level (a role
can publish to `a2a.<self>.tasks.>` but not to another role's subjects).
Skill validation is client-side only — the dispatcher trusts the
requester's `skill` field without server verification.

A worker receiving a task for a skill it doesn't advertise silently
rejects or mishandles it. The bouncer closes this gap at the
coordinator level before dispatch.

## Deliverables

### 1. Bouncer service

New script or Python module `scripts/a2a-bouncer.sh` (or
`mcp-server/src/aon_mcp/a2a/bouncer.py`) that subscribes to
`a2a.*.tasks.send` as a queue-group interceptor.

For each incoming `tasks/send` message:
1. Parse `skill` from payload.
2. Load target role's card via `cards.load_card(target_role)`.
3. If skill not in card's `skills` list → reject with
   `{error: "skill_mismatch", skill, target_role}` on reply subject.
4. Forward to target if valid (or let request-reply pass through).

### 2. Integration with dispatcher

`a2a/dispatcher.py:dispatch_task()` already validates skill match
against cards before sending (line ~95). The bouncer adds a
server-side second check that works even for direct publishes
bypassing the dispatcher.

Document the two-layer defence in `MODEL.md` §A2A layer.

### 3. Coordinator spawn

Bouncer started as a background process by `aon launch` when
`AON_ROLE=sun` (coordinator). Add to `cmd_launch()` in `bin/aon`
alongside the existing warmup/classifier logic.

### 4. Smoke 22

`scripts/smoke/22-a2a-bouncer.sh`:
- Send task with valid skill for target → passes.
- Send task with skill not in target's card → rejected with
  `skill_mismatch`.
- Verify bouncer does not add latency >50 ms on fast path.

## Acceptance

- [ ] Skill mismatch rejected at server side before worker sees it.
- [ ] Smoke 22 green.
- [ ] Bouncer restarts cleanly on card reload (mtime invalidation).
- [ ] No regression in smoke 17–21.

## Refs

- `team-alpha-a2a-impl-slice1.md` defect resolution §5 — original
  sketched this as post-MVP.
- `mcp-server/src/aon_mcp/a2a/dispatcher.py:~95` — client-side check.
- `mcp-server/src/aon_mcp/a2a/cards.py` — card loader.
- `MODEL.md:288` — A2A layer spec.
