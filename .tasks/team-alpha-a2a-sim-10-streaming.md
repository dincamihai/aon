---
column: Backlog
created: 2026-04-26
order: 141
---

# Sim 10 — A2A streaming chunks

Worker emits multiple `.message` chunks during long-running work
between `.status=working` and `.status=completed`. Maya can observe
in real time via subscription on `a2a.<role>.tasks.<id>.message`.

## Deliverables

### 1. Worker tool: `a2a_emit_message`

`team_alpha_mcp/__main__.py` adds:
- `a2a_emit_message(task_id, chunk, kind="text")` — publishes on
  `a2a.<self>.tasks.<task_id>.message`. Schema: `{task_id, kind,
  chunk, by, ts}`. No lifecycle transition (intermediate).

ACL already covers (slice 1 publish allow on `a2a.<self>.tasks.>`).

### 2. Sim scenario 10

`scripts/sim/scenario-10-a2a-streaming.sh`:
1. Maya dispatches skill=python.
2. Worker (lin) auto-accepts, emits 5 `.message` chunks at 100ms
   intervals, then `.status=completed`.
3. Sim subscribes `a2a.lin.tasks.<id>.message` and asserts ≥5
   chunks observed in order.
4. AUDIT contains the 5 message events + working + completed.

### 3. Smoke 23

`scripts/smoke/23-a2a-streaming.sh`:
- worker pubs 3 `.message` events for one task_id
- assert all visible via stream view on A2A_TASKS
- ACL: cross-role pub on `<other>.tasks.<id>.message` denied
  (already covered by slice 2 smoke 19; add a sanity assertion)

## Acceptance

- [ ] `a2a_emit_message` MCP tool registered + tested.
- [ ] Sim 10 green; chunks observed in order.
- [ ] Smoke 23 green; existing suite unchanged.

## Refs

- `team-alpha-a2a-impl-slice3.md` — umbrella.
