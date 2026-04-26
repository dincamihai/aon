---
column: Backlog
created: 2026-04-26
order: 125
---

# A2A on NATS — implementation slice 1 (Week 1 cut)

Implements first week of `team-alpha-a2a-investigation.md` migration
timeline, after that card's "Decision (2026-04-26): adopt, sliced".
Scope is deliberately narrow: enough A2A surface for one worker to
accept and complete one task end-to-end, with audit + ACL coverage.

Out of scope for this slice (pushed to slice 2+): HTTP bridge,
watcher integration, sim scenarios 09-11, dual-run cutover of
existing `board.tasks.>` events, MCP tool surface beyond the two
needed for the smoke.

## Deliverables

### 1. Agent cards in git

`agents/<role>.json` for maya, raj, lin, sam, diego, priya. Generated
from [acl.py](mcp-server/src/team_alpha_mcp/acl.py) by a small script.

Skill mapping rule:
- `TASK_DOMAINS[role]` → skill with `tier: "primary"`
- `LEARNING_CLAIM_DOMAINS[role] - TASK_DOMAINS[role]` → skill with `tier: "growing"`
- `MENTOR_DOMAINS[role]` → skill flag `mentor: true`

Auth: `{ "scheme": "nats-user", "user": "<role>" }`. JWT swap deferred
to card 70.

Endpoints: NATS-only for v1.
```json
"endpoints": {
  "tasks_send":  "nats://<host>:4222 a2a.<role>.tasks.send",
  "task_status": "nats://<host>:4222 a2a.<role>.tasks.*.status"
}
```

Generator: `scripts/gen-agent-cards.py` — writes `agents/*.json`
deterministically (sorted keys, stable order). CI check: re-run + `git
diff --exit-code agents/`. Fails if drift between acl.py and
agents/*.json.

### 2. ACL adds in nats/auth.conf

Per drift resolution #1 (glob+deny style):

Each worker role:
```
publish allow   += "a2a.<role>.tasks.>"
                   "a2a.discovery.<role>"
subscribe allow += "a2a.<role>.tasks.send"
                   "a2a.<role>.tasks.*.cancel"
```

Maya:
```
publish allow   += "a2a.*.tasks.send"
                   "a2a.*.tasks.*.cancel"
                   "a2a.discovery.>"
subscribe allow += "a2a.>"
```

Apply same change to `nats/auth.conf.example`.

### 3. JetStream streams

Add to [bootstrap script / docker-compose init](nats/):
```
A2A_TASKS  subjects: ["a2a.*.tasks.>"]    retention: limits  max-age: 30d
A2A_DISC   subjects: ["a2a.discovery.>"]  retention: limits  max-msgs-per-subject: 1
```

AUDIT stream: add `a2a.>` to its source filters (existing pattern).

### 4. MCP A2A subpackage

`mcp-server/src/team_alpha_mcp/a2a/`:

- `__init__.py`
- `schemas.py`     — Task, Message, Artifact JSON Schemas (subset of
                    A2A spec needed for slice 1: id, state, payload,
                    artifact). Pydantic models + `validate(payload)`.
- `cards.py`       — load `agents/<role>.json` from local repo path
                    (file-system, no GitHub raw fetch yet); cache in
                    memory; `resolve_by_skill(skill, tier)` returns
                    candidate roles.
- `lifecycle.py`   — state machine. A2A canonical states only:
                    submitted, working, input-required, completed,
                    failed, canceled. Preemption `parked` maps to
                    `input-required` with `reason: "preempted"` at
                    the boundary. `transition(task_id, from, to)`
                    raises on illegal moves.
- `dispatcher.py`  — `dispatch(skill, payload, parent_task_id=None,
                    project_id=None)`:
                    1. resolve candidates via cards
                    2. apply continuity bias (AUDIT lookup on
                       parent_task_id; KV `project.<pid>.last_worker`)
                    3. else load-aware via KV `agent.<role>.load`
                    4. NATS `a2a.<chosen>.tasks.send` request, reply
                       on `_INBOX`

### 5. MCP tools (minimal pair)

Two new tools, registered in existing MCP server (card 110):

- `a2a_send_task(skill, payload, parent_task_id=None, project_id=None)`
  — coord-side. Maya only (manager check). Returns `{task_id, target_role}`.
- `a2a_update_status(task_id, state, message=None, artifact=None)`
  — worker-side. Publishes `a2a.<self>.tasks.<task_id>.status`.
  Validates transition via lifecycle.py.

`a2a_accept_task` / `a2a_cancel_task` / `a2a_resolve_agent` deferred
to slice 2.

### 6. Smoke test

`scripts/smoke/17-a2a-roundtrip.sh`:
1. as maya: `a2a_send_task(skill="terraform", payload={...})`
2. assert reply task_id
3. as priya: subscribe `a2a.priya.tasks.send`, accept incoming, call
   `a2a_update_status(task_id, "working")` then `"completed"`
4. assert AUDIT stream contains both status events
5. assert priya picked (skill=terraform primary candidate, no other
   primary)

Add to `scripts/smoke/run-all.sh`.

### 7. Docs

Append to MODEL.md a §"A2A layer" section: subject taxonomy, lifecycle
states, dispatch rule, link to investigation card for rationale.

## Acceptance

- [ ] `agents/*.json` × 6 committed; `scripts/gen-agent-cards.py`
      regenerates byte-identical output.
- [ ] CI job (or `make check`) fails on drift between acl.py and
      agents/*.json.
- [ ] `nats/auth.conf.example` updated; ACL smoke (existing 01) still
      passes; new subjects covered.
- [ ] A2A_TASKS + A2A_DISC streams created on `docker-compose up`.
- [ ] Two MCP tools registered, callable from agent prompts.
- [ ] `scripts/smoke/17-a2a-roundtrip.sh` green; included in run-all.
- [ ] All existing smokes + sims still pass (no regression).
- [ ] MODEL.md updated.

## Decisions deferred

Recorded so future engineers don't relitigate; addressed in slice 2+.

1. **Pull-vs-push hybrid (slice 2).** Keep `board.tasks.<d>.pending`
   workqueue for "anyone-can-grab" tasks; A2A `tasks/send` for
   skill-targeted directed dispatch. Restores generalist self-route
   property (MODEL.md §"Generalists self-route") that pure A2A
   directed dispatch would lose. Two flows, intentional split.

2. **Skills source-of-truth (slice 2).** `agents/<role>.json` in git
   is authoritative. Deprecate KV `agent.<role>.skills` — remove
   writes, migrate readers. Slice 1 lands the git files; slice 2
   does the KV cleanup.

3. **State vocabulary doubled (documented, no action).** A2A
   canonical names (submitted/working/input-required/completed/
   failed/canceled) are the single agent-facing vocabulary going
   forward. Substrate `board.tasks.<d>.<pending|claimed|...>`
   subjects continue at infra level; mapping happens at boundary in
   `lifecycle.py`. Agents learn one vocabulary.

4. **Per-skill ACL (slice 2+).** Honor system for MVP. Server ACL
   stays per-role (`a2a.<role>.tasks.>`); skill-match enforcement is
   client-side routing only. Post-MVP a coordinator/admin-spawned
   bouncer service validates skill claims against agent cards before
   forwarding `tasks/send`.

5. **Validation gateway (post-MVP).** Honor system in slice 1.
   Coordinator/admin role spawns gateway/bouncer post-MVP — same
   service as #4, broadened to schema validation across all A2A
   subjects (replaces MODEL.md §"validation gateway" that was never
   built).

## Out of scope (slice 2+)

- HTTP+SSE bridge for external A2A interop.
- Watcher integration (`a2a.*.tasks.*.status` stale detection,
  duplicate-dispatch detection).
- Sim scenarios 09 (dispatch by skill match), 10 (streaming),
  11 (cancel).
- Dual-write cutover from `board.tasks.>` broadcast to A2A directed
  dispatch.
- Smokes 18 (discovery) + 19 (ACL coverage of a2a subjects).
- Tools: `a2a_accept_task`, `a2a_cancel_task`, `a2a_resolve_agent`.
- GitHub-raw card fetch + ETag caching.

## Refs

- `team-alpha-a2a-investigation.md` — parent decision card.
- card 110 (mcp-server) — MCP host this slice plugs into.
- defect-204 — ACL pattern this slice follows.
- card 85 (preemption) — source of `parked` lifecycle state.
- card 70 (nsc-jwt-migration) — auth scheme upgrade, post-MVP.
