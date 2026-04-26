---
column: Backlog
created: 2026-04-26
order: 151
---

# Live test — lightweight (maya + priya, one task)

Smallest possible end-to-end LLM-driven test. Two real Claude Code
sessions, one task, observed via AUDIT in a third terminal. Catches
the obvious agent-UX defects before committing to a full mob.

## Setup

### 1. MCP server installable

```bash
cd mcp-server
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
team-alpha-mcp --help    # smoke check
```

Verify the venv path is what the smokes already use
(`mcp-server/.venv/bin/python`) so test infra and live infra share
the same install.

### 2. Per-role credentials

```bash
mkdir -p ~/.team-alpha && chmod 700 ~/.team-alpha
for r in maya priya; do
  printf '%s' "$NATS_PASSWORD_FOR_$r" > ~/.team-alpha/$r.password
  chmod 600 ~/.team-alpha/$r.password
done
```

For dev: all six passwords = `devpass` (matches auth.conf default).

### 3. Two Claude Code sessions

Session A (maya):
```bash
TEAM_ALPHA_ROLE=maya \
TEAM_ALPHA_NATS_URL=nats://localhost:4222 \
TEAM_ALPHA_CREDS=~/.team-alpha/maya.password \
claude mcp add team-alpha --transport stdio team-alpha-mcp
claude  # start session
```

Session B (priya): same env with ROLE=priya.

### 4. AUDIT observer (third terminal)

```bash
nats --server nats://localhost:4222 --user sysadmin --password devpass \
  sub 'a2a.>,board.>' --raw
```

## Test scenarios

### T1 — push dispatch happy path

1. **Maya prompt**: "Dispatch a terraform task: add staging VPC peering."
2. **Expected**: maya invokes `a2a_send_task(skill="terraform",
   payload={"summary":"add staging VPC peering"})`. Returns
   target_role=priya (load-aware tiebreak).
3. **Priya prompt** (in parallel): "You are the A2A worker priya.
   Watch your inbox; when a task arrives, accept and report progress."
4. **Expected**: priya's accept loop auto-acks (lifespan-started in
   slice 2). She invokes `a2a_update_status(task_id, "completed",
   artifact={...})` after "doing the work" (LLM may simulate by
   describing the change).
5. **Observer**: AUDIT shows `a2a.priya.tasks.<id>.status`
   working → completed.

### T2 — pull dispatch

1. **Maya prompt**: "Pull-dispatch a python task: write a smoke test
   for the new endpoint." (Hint at pull mode in prompt.)
2. **Expected**: maya invokes `a2a_send_task(skill="python",
   dispatch_mode="pull", ...)`. Posts to `board.tasks.python.pending`.
3. Skip priya here — pull mode ends at the workqueue. Verify
   observer shows the substrate publish, no a2a.priya.tasks.send.

### T3 — cancel mid-flight

1. **Maya prompt**: "Dispatch a long terraform refactor."
2. (Priya accepts via her loop, emits `.status=working`.)
3. **Maya follow-up**: "Cancel that — it's out of scope this cycle."
4. **Expected**: maya invokes `a2a_cancel_task("priya", <id>)`.
5. **Observer**: AUDIT shows `.status=canceled`; KV
   `a2a.priya.inflight` clears.

### T4 — error surface readability

1. **Maya prompt**: "Dispatch a Rust task." (No role advertises rust.)
2. **Expected**: maya gets `{ok:false, error:"no agent advertises
   skill='rust'"}`. The agent should explain the failure to the user
   without retrying or hallucinating a target.

## What we're measuring

- Tool selection: does maya pick `a2a_send_task` over `post_task`
  when the prompt implies dispatch?
- Payload shape: agents fill required fields without hand-holding.
- Error parsing: agents recognize `{ok:false}` as failure.
- AUDIT use: does either agent voluntarily call `recent_events` to
  check state vs. asking the operator?

## Deliverables

- `docs/live-test-lightweight-runbook.md` — this card promoted to
  durable runbook after first successful run.
- Defect cards for any agent-UX issue (tool naming, prompt clarity,
  error message wording).

## Acceptance

- [ ] T1-T4 pass with no operator intervention beyond the initial
      prompts.
- [ ] Defects filed for friction observed.
- [ ] Runbook checked in.

## Out of scope

- All six roles (→ card 152).
- Stress / soak testing.
- Multi-org federation.

## Refs

- `team-alpha-a2a-live-test.md` — umbrella.
- `team-alpha-a2a-impl-slice3.md` — what we're validating.
