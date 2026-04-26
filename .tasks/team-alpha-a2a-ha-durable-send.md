---
column: Backlog
created: 2026-04-26
order: 163
---

# A2A durable tasks.send (survives total outage)

Today `a2a.<role>.tasks.send` is core NATS request-reply (slice 1
decision: keep out of JetStream so JS-ack doesn't race the worker
reply). Cost: if every instance of role X is offline at dispatch
time, request times out and the task is lost.

This card decouples request from response so the request can live
in a workqueue stream while the response stays request-reply via
a sibling subject.

## Deliverables

### 1. Subject taxonomy split

```
a2a.<role>.tasks.send                 (ephemeral request, kept)
a2a.<role>.tasks.queue                (NEW — workqueue stream)
a2a.<role>.tasks.<id>.ack             (NEW — worker → maya ack)
```

Maya picks ONE of two paths via new field `delivery: "live"|"queued"`
on `a2a_send_task`:

- `"live"` (default for backward-compat) = slice-1 path, request-
  reply on `.send`.
- `"queued"` = publish to `.queue` (workqueue stream A2A_QUEUE,
  retention=workqueue, max-age=24h). Worker pulls; ack via
  `a2a.<role>.tasks.<id>.ack`. Maya subscribes to that ack subject
  before publishing.

### 2. Stream A2A_QUEUE

`scripts/lib/nats-helpers.sh` + `bootstrap.sh`:

```
A2A_QUEUE   subjects: a2a.*.tasks.queue   retention: workqueue
            max-age: 24h    max-msgs-per-subject: -1
```

Workqueue retention = msg deleted on first ack. Multi-instance
queue group (card 161) competes for pulls.

### 3. Worker pull consumer

`a2a/worker.py`: instead of plain subscribe on `.queue`, use a
durable pull consumer (per role, durable name `a2a-queue-<role>`).
ack-policy=explicit. On valid task, ack + run normal handler.

### 4. ACL update

Worker pub allow += `a2a.<role>.tasks.*.ack`.
Maya sub allow += `a2a.>` (already covered).

### 5. Smoke 29

- maya dispatches w/ `delivery="queued"` while NO priya instance
  online
- task lands in A2A_QUEUE; verify msg count = 1
- start priya instance
- assert priya receives via durable pull, ACKs queue, processes,
  publishes status=working

### 6. Sim 14 — total outage recovery

`scripts/sim/scenario-14-total-outage.sh`:
- spin up priya, dispatch 3 tasks queued mode → all complete
- kill priya before 4th dispatch; dispatch task #4
- restart priya 5s later; assert task #4 picked up + completed

### 7. Documentation

MODEL.md §"A2A layer" updated with the live-vs-queued tradeoff
table:

| mode | latency | durability | use when |
|---|---|---|---|
| live | ms | none if all offline | online, low-latency, agent UX |
| queued | ms-to-seconds | 24h JetStream | offline-tolerant batch / overnight work |

## Acceptance

- [ ] A2A_QUEUE stream + ACL adds + bootstrap green.
- [ ] Worker pulls via durable consumer; queue dedup with card 161
      queue groups still works.
- [ ] Smoke 29 + sim 14 green.
- [ ] No regression in `delivery="live"` path (== slice 1 path).

## Out of scope

- TTL eviction back to dead-letter queue (slice 4+).
- Priority within queue (use NATS-default FIFO).

## Refs

- `team-alpha-a2a-ha-resilience.md` — umbrella.
- `team-alpha-a2a-ha-queue-groups.md` (161) — queue-group dedup.
- `team-alpha-a2a-investigation.md` §"Library or roll our own" —
  original ephemeral .send decision; this card revisits.
