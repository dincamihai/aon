---
column: Backlog
created: 2026-04-26
order: 213
---

# Card 213 — Runtime task board (markdown cards consumed by team-alpha)

## Why

Today the only way to feed work into the team is for the operator to
type a natural-language prompt at maya ("dispatch a terraform task:
add staging VPC peering"). Maya invents the rest from her role brief.
That works for tests, not for real work — there's no shared
specification of what the task means, what success looks like, or
what artifacts to return.

A runtime task board fixes this: each task is a markdown card with
frontmatter + structured sections (Why, Spec, Files, Acceptance,
Refs). Maya watches the board, picks the next card, dispatches the
full card to a worker. Worker reads the card, executes, returns the
artifact, marks the card Done.

This mirrors how Mihai's saas team's `.tasks/` kanban already works
(humans + Claude Code) — extended to the team-alpha agent fleet.

## Card format

Path: `~/team-alpha-board/inbox/<id>.md` (operator drops here),
moves to `~/team-alpha-board/in-progress/<id>.md` when claimed,
`~/team-alpha-board/done/<id>.md` when complete.

Frontmatter:

```yaml
---
id: tb-2026-04-26-vpc-peering
column: inbox        # inbox | in-progress | done
created: 2026-04-26T18:30:00Z
priority: medium     # low | medium | high
skill: terraform     # primary skill required
target: priya        # optional — manual override
parent_task_id: ...  # optional — for follow-ups
project_id: ...      # optional — for grouping
---
```

Body sections (same shape as dev `.tasks/`):

```markdown
# tb-2026-04-26-vpc-peering — Add staging VPC peering

## Context
Why this matters, who asked.

## Spec
What needs to be done. Concrete enough that a worker can execute
without asking the operator. Use ASK loop via a2a_emit_message if
the worker still needs clarification.

## Files
Paths to touch. Repo root assumed if relative.

## Acceptance
Bulleted, testable.

## Refs
Links to PRs, ADRs, prior cards, NATS subjects.
```

## Workflow

### Operator

1. Drop a card in `~/team-alpha-board/inbox/<id>.md`.
2. (Optional) Publish a `board.tasks.<domain>.pending` event so
   maya's Monitor wakes immediately. Or rely on filesystem-watch
   hook (below).
3. Walk away.

### Maya (dispatcher)

1. Filesystem-watch hook on `~/team-alpha-board/inbox/` (e.g. via
   `fswatch` on macOS) → publishes `board.tasks.<skill>.pending`
   on file create. Maya's Monitor catches.
2. Maya reads the card via `Read` tool, parses frontmatter, picks
   target role from `agents/<role>.json` skill map (or honors
   `target:` override).
3. Calls `a2a_send_task(skill, payload={summary, card_path,
   acceptance})`. card_path lets the worker re-read live.
4. Moves card `inbox/` → `in-progress/`. Updates frontmatter
   `column:` + adds `claimed_by:` + `task_id:`.

### Worker (priya/raj/etc.)

1. Receives a2a task. card_path in payload.
2. Reads card, executes per Spec/Acceptance.
3. Emits `a2a_emit_message` for clarifications (rare).
4. On completion: `a2a_update_status(task_id, "completed",
   artifact={summary, files_changed, test_results})`.
5. Updates card frontmatter `column: done`, moves file to
   `done/<id>.md`, appends a `## Result` section with artifact.

### Observer (operator)

- `~/team-alpha-board/done/` is the audit trail. Each card is its
  own postmortem.
- AUDIT replay covers the NATS-side trace.

## Files

- `scripts/runtime-board/board.sh` — CLI to create / move / list
  cards (`board add`, `board list`, `board view <id>`,
  `board promote <id>` if needed).
- `scripts/runtime-board/fswatch-publish.sh` — filesystem-watch
  daemon. On create in `inbox/`, publish
  `board.tasks.<skill>.pending`.
- `scripts/runtime-board/install.sh` — wire the daemon into
  launchd / systemd / a tmux pane.
- `agents/<role>.json` — already has skills; extend with
  `accepts_card_paths: true` flag if needed.
- `mcp-server/src/team_alpha_mcp/__main__.py` — add `board_pick()`
  MCP tool for maya: lists `inbox/` cards, returns oldest by
  priority + age.
- `scripts/agent-prompts/maya.md` — add "Runtime board" section.
- `scripts/agent-prompts/<worker>.md` × 5 — add "Reading task
  cards" section.

## Acceptance

- [ ] Operator runs `board add --skill terraform "add staging VPC
      peering"` — card lands in `~/team-alpha-board/inbox/`.
- [ ] fswatch daemon publishes `board.tasks.terraform.pending` on
      file create.
- [ ] Maya's Monitor delivers the event; she calls `board_pick()`,
      reads the card, dispatches via `a2a_send_task` with
      `card_path` in payload.
- [ ] Priya receives, reads card, executes, completes — card moves
      to `done/` with `## Result` section.
- [ ] No operator turn between dispatch and completion.

## Open questions

- Repo location: dedicated repo `team-alpha-board/`, or a sibling
  dir under `~/`? Recommend `~/team-alpha-board/` outside any repo
  so it can be wiped without affecting code.
- Versioning: do we git-track done cards? Probably yes — auditable
  history of work done.
- Multi-operator: today single-user. If multi, add `created_by:`
  field. Out of scope for v1.

## Out of scope

- A web UI / kanban board view. CLI + filesystem is enough.
- Automatic card generation from external systems (Jira, GH issues).
- Cross-team boards (other teams beyond team-alpha).

## Refs

- `~/Repos/saas/.tasks/` — pattern source.
- Card 60 — explicitly excluded `.tasks/` from runtime concerns;
  213 is the runtime layer.
- Card 210 — Monitor pattern that delivers `board.>` events.
- Card 212 — status pings from worker via post-tool hooks.
