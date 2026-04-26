---
column: Backlog
created: 2026-04-26
order: 164
---

# A2A ownership lease + heartbeat → auto-recover crashed mid-work

Worker accepts a task, KV inflight = working, then crashes. Today
the inflight entry stays orphaned until watcher emits
`a2a_orphan_inflight` after $A2A_INFLIGHT_TTL — recovery is manual
(Maya re-dispatches).

This card adds a TTL-bounded lease + heartbeat so peer instances
can auto-claim a stale lease and resume the task.

## Deliverables

### 1. Lease fields in inflight KV

`a2a.<role>.inflight[task_id]` gains:
- `owner_instance: str`  — UUID per process
- `lease_until: iso`     — now + LEASE_TTL (default 60s)
- `heartbeat_seq: int`   — incremented each tick

### 2. Background heartbeat task

`a2a/worker.py` adds heartbeat loop alongside accept loop:

```python
async def heartbeat_loop(client, instance_id):
    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL)  # 20s
        for task_id, entry in await read_owned_inflight(client, instance_id):
            await extend_lease(client, task_id, instance_id)
```

CAS-aware (depends on card 161).

### 3. Stale-lease takeover

When worker auto-accepts a tasks.send / pulls from queue, before
recording inflight it checks if same task_id already has stale
lease (`now > lease_until`). If yes:
- log takeover
- replace `owner_instance` with self
- proceed normally
- emit `state.alert.a2a_lease_takeover {task_id, prior_owner}`

### 4. Watcher detection

Coordinator-watcher gets a new condition: `a2a_lease_expired` —
inflight entry exists with `now > lease_until + grace` AND no
takeover happened (no recent same-task status update). Emits
alert; ops decides whether Maya re-dispatches.

### 5. Smoke 30

- spawn 2 priya instances
- dispatch task; one accepts (instance A)
- kill instance A mid-work (no .status=completed)
- wait > LEASE_TTL
- redispatch same task_id (idempotent — same skill/payload)
- assert instance B takes over via stale-lease check

### 6. Sim 15 — heartbeat resilience

`scripts/sim/scenario-15-heartbeat.sh`:
- 2 instances, dispatch task
- one accepts, runs heartbeat for 90s while "working"
- assert lease_until extends each interval, no takeover by peer
- complete normally; assert lease cleared with terminal state

## Acceptance

- [ ] Lease fields populated on accept.
- [ ] Heartbeat extends lease while alive.
- [ ] Stale-lease takeover works, alert emitted.
- [ ] Smoke 30 + sim 15 green.
- [ ] Watcher emits `a2a_lease_expired` correctly.

## Out of scope

- Multi-region lease coordination (single cluster only).
- Cooperative work-stealing across roles (post-MVP).

## Refs

- `team-alpha-a2a-ha-resilience.md` — umbrella.
- `team-alpha-a2a-ha-durable-send.md` (163) — needed for redelivery
  semantics.
- `team-alpha-a2a-ha-queue-groups.md` (161) — CAS infra.
