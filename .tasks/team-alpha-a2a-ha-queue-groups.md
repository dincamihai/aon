---
column: Backlog
created: 2026-04-26
order: 161
---

# A2A queue groups + KV-inflight CAS

Two changes ship together: NATS queue subscriptions for tasks.send
+ inbox so multi-instance dedupes; KV inflight via revision-based
CAS so concurrent disjoint-task updates don't lose data.

## Deliverables

### 1. Queue subscriptions

`mcp-server/src/team_alpha_mcp/a2a/worker.py`:

```python
sub_send   = await nc.subscribe(send_subject,
                                queue=f"a2a-send-{role}", cb=...)
sub_cancel = await nc.subscribe(cancel_subject,
                                queue=f"a2a-cancel-{role}", cb=...)
```

`__main__.py` (DM inbox handler — slice 2 didn't have a daemon
loop on it, but this card adds one for HA correctness):

```python
sub_inbox = await nc.subscribe(f"agents.{role}.inbox",
                                queue=f"inbox-{role}", cb=...)
```

NATS guarantees exactly one delivery per queue group. N instances
of priya = round-robin distribution.

### 2. KV-inflight CAS

`mcp-server/src/team_alpha_mcp/a2a/worker.py`:

- `update_inflight(client, task_id, new_state, *, terminal)` already
  reads-then-writes. Replace with revision-aware loop:

  ```python
  for _ in range(5):
      entry = await client.kv().get(key)        # returns Entry w/ revision
      val = json.loads(entry.value or b"{}")
      ...mutate val...
      try:
          await client.kv().update(key, body, last=entry.revision)
          return
      except KeyValueError:
          continue   # someone wrote first; retry
  raise RuntimeError("CAS failed after 5 retries")
  ```

- Same pattern in `_record_inflight`.

### 3. ACL update

Auth.conf needs no change (queue groups are NATS-internal; subjects
unchanged).

### 4. Smoke 26

`scripts/smoke/26-a2a-queue-dedup.sh`:
- start 2 priya accept loops in parallel subprocesses
- maya dispatches 5 distinct tasks.send rapidly
- assert each task is accepted by exactly one instance (no
  duplicate AUDIT status events for any task_id)
- assert KV inflight contains all 5 tasks (no lost updates)

### 5. Smoke 27

`scripts/smoke/27-a2a-inflight-cas.sh`:
- 2 instances concurrently update_inflight on disjoint task_ids
- assert final KV state contains both tasks

## Acceptance

- [ ] Worker accept loop uses queue groups; smoke 26 green.
- [ ] update_inflight + _record_inflight use CAS retry; smoke 27 green.
- [ ] No regression in slice 1-3 smokes/sims (single-instance still
      works — queue group with one member is identical to plain sub).

## Refs

- `team-alpha-a2a-ha-resilience.md` — umbrella.
- `team-alpha-a2a-impl-slice3.md` — what we're hardening.
