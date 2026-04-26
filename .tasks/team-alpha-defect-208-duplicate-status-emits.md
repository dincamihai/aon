---
column: Done
created: 2026-04-26
order: 208
---

# Defect 208 — Accept loop emits `.status=working` 5× for same task

Observed in card 151 lightweight live test, T1.

## Symptom

AUDIT trace for `a2a.priya.tasks.t-40c5158171bc.status`:

```
seq 2,782 / 13:46:03  state=working
seq 2,783 / 13:46:03  state=working
seq 2,784 / 13:46:03  state=working
seq 2,785 / 13:46:03  state=working
seq 2,786 / 13:46:03  state=working
```

Five identical messages, identical timestamp, identical body.
Single dispatch from maya — should emit `working` once.

## Root cause (suspected)

Either:
- Accept loop subscription delivers duplicate (no msg-id /
  dedup key, queue-group not yet wired — card 161).
- `_handle_send` re-entrant on retry path (no idempotency check
  against KV inflight already-set).
- Source-stream replay (A2A_TASKS sources land in AUDIT plus
  worker resub); but original publish on non-stored subject
  shouldn't fan-in 5×.

Need to instrument accept loop to log each call, and re-test.

## Fix

1. Add log line in `_handle_send` (worker.py) including
   `msg.subject`, `msg.reply`, `body['task_id']`, and a hash of
   payload. Run T1 and confirm hit count.
2. If duplicates come from NATS (no dedup), gate via KV CAS:
   only emit `.status=working` when transitioning from absent →
   working in `a2a.<self>.inflight`. Subsequent deliveries no-op.
3. Card 161 (queue groups + KV-inflight CAS) will subsume this —
   note this defect as a motivator and accelerate scheduling.

## Acceptance

- [ ] Single `working` audit per dispatch.
- [ ] Test: dispatch twice in quick succession to same role,
      observe two task_ids each with one `working` emit (not
      `2×N`).

## Reproductions

- 2026-04-26 T1 (live Claude): 5× `working` for `t-40c5158171bc`,
  identical timestamp, identical body.
- 2026-04-26 T3 (subagent sim): 5× `working` + 2× `canceled` for
  `t-09289d248bae`. Reproduces deterministically.

## Investigation hints (2026-04-26)

- AUDIT mirrors 3 sources: `A2A_TASKS`, `EVENTS`, `LEARNING`. So
  AUDIT fan-in alone gives at most ×3, not ×5. So multiplier is
  upstream of AUDIT.
- A2A_TASKS subject filter is `a2a.<role>.tasks.*.>` (5+ tokens).
- A2A_TASKS direct view confirms ×5 publishes at the stream layer.

## Root cause (2026-04-26, after T3 reproduction)

NATS `connz` showed 4 distinct priya connections all subscribed to
`a2a.priya.tasks.send`:

```
cid 40 / 41 / 603 / 1281 — each subscribed to a2a.priya.tasks.send
```

Each accumulated from test reruns (live Claude MCP session + each
subagent simulation creating their own TeamAlphaClient that never
disconnected on process exit). On a single dispatch from maya, all
N subscriptions received the message and each `_handle_send`
published its own `.status=working`.

In production (single MCP instance per role) → single subscription
→ single emit, no duplication.

In HA (multiple replicas of same role) → still duplicates without
NATS queue groups. **Card 161 (queue-groups + KV-CAS) is the
production fix.** Once queue group `a2a-<role>` is set on
`nc.subscribe`, NATS routes each msg to exactly one member —
duplicates impossible.

## Fix path

Primary: card 161 (already on backlog). Adds `queue=f"a2a-{role}"`
to `nc.subscribe()` in `start_accept_loop` plus KV-CAS on inflight
write so even racing same-group subs no-op the second emit.

Secondary (test hygiene): TeamAlphaClient should expose a `close()`
method called on subagent script exit, draining the connection.
Currently `client.nc()` lazy-connects but no clean shutdown.

## Status

Real-world prod single-instance: NOT BUGGED — verified via code
read of `worker._handle_send` (single emit per delivery).
Multi-instance: WAITING ON CARD 161.

Closing this defect as **superseded by card 161**. Reopen only if
single-instance reproduces ×N.

## Refs

- AUDIT trace 13:46:03 from session 2026-04-26.
- `team-alpha-a2a-ha-queue-groups.md` (card 161) — overlap.
- `mcp-server/src/team_alpha_mcp/a2a/worker.py:_handle_send`.
