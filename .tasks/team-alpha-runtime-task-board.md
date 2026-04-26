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

## Assignment modes

A card can specify how it wants to be routed via frontmatter:

| Frontmatter            | Mode             | Maya behavior                                              |
|------------------------|------------------|------------------------------------------------------------|
| `target: priya`        | pre-assigned     | `a2a_send_task(skill, dispatch_mode="push")` directly to priya |
| (no `target`, has `skill`) | skill-matched | look up `agents/<role>.json`, pick tier-1 by continuity → project-last-worker → lowest load, push |
| `mode: pull`           | self-claim       | translate skill → domain, publish `board.tasks.<domain>.pending`; any worker in domain `claim_task`s. Maya stays out of routing. |

Defaults: `mode: push`, target absent → skill-matched auto-push.
Operator picks pull when ≥2 equally-good candidates exist or when
load-balancing matters more than continuity.

The dispatcher (`a2a_send_task` in `mcp-server/src/team_alpha_mcp/__main__.py`)
already implements push + pull. Maya's only addition for the runtime
board is honoring an explicit `target:` override before falling
back to skill-match.

## NATS payload vs. card body — split

NATS is the **notification + lifecycle** layer. Files are the
**content** layer. Don't put card bodies in NATS payloads.

`board.tasks.<domain>.pending` payload (≤ 1 KB):

```json
{
  "task_id": "tb-2026-04-26-vpc-peering",
  "slug":    "tb-2026-04-26-vpc-peering",
  "skill":   "terraform",
  "summary": "add staging VPC peering",
  "priority":"medium",
  "card_path": "/Users/mid/team-alpha-board/inbox/tb-2026-04-26-vpc-peering.md",
  "by":      "operator",
  "ts":      "2026-04-26T18:30:00Z"
}
```

Receivers read `card_path` for the full spec. Two reasons:

- AUDIT stream stays small (1y retention applies to lifecycle, not
  prose).
- Cards are easy for humans to author, diff, and version in git.
  NATS is the wrong place for a 50-line markdown body.

The `a2a_send_task` payload from maya to worker carries the same
`{task_id, summary, card_path, skill}` — worker reads the file
itself, not the payload.

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

## board-tui integration

`mcp__board-saas__*` tools (board-tui-mcp) already manage
markdown cards in a `.tasks/` directory: `create_task`, `list_tasks`,
`move_task`, `update_task`, `get_task`, `delete_task`,
`list_columns`. We reuse them — no new TUI to build.

Wiring:

1. Run a second board-tui-mcp instance pointed at
   `~/team-alpha-board/`:
   ```
   board-tui-mcp --tasks-dir /Users/mid/team-alpha-board/
   ```
   Register as MCP server `team-alpha-board` in maya + workers'
   per-role `.mcp.json`.
2. Operator (in their own session) calls
   `mcp__team-alpha-board__create_task(column="inbox",
   frontmatter={skill, priority, target?},
   body="<markdown>")` — board-tui writes the file.
3. **NATS publish on task mutation** — the board layer itself
   publishes `board.tasks.<skill>.pending` (or `.claimed`, `.done`)
   atomically with each create / move / update. Two implementations:
   - **A (recommended)**: patch board-tui-mcp so its tools publish
     after writing the file. Single host-agnostic source of truth.
   - **B (lighter)**: a thin team-alpha MCP wrapper tool
     `board_create / board_move / board_update` that delegates to
     board-tui then publishes. Operators use the wrapper; raw
     board-tui tools stay available but don't publish.
   Don't use fswatch — host-local, blind to container / multi-host
   writes.
4. Maya's Monitor catches; she calls
   `mcp__team-alpha-board__get_task(slug)` to read the card,
   then `mcp__team-alpha-board__move_task(slug, "in-progress",
   {claimed_by:"priya", task_id:"<a2a-id>"})`, then
   `a2a_send_task` to priya with `card_path`.
5. Priya reads card via `Read` (or board-tui get_task), works,
   marks `a2a_update_status(...,"completed",artifact)`. Hook on
   completion appends `## Result` section + moves to `done/`
   via `mcp__team-alpha-board__update_task` +
   `move_task(slug, "done")`.

Manual reassignment: operator types in their session
"reassign tb-... to raj", they call
`mcp__team-alpha-board__update_task(slug, frontmatter={target:"raj"})`,
then republishes board.tasks event. Maya respects `target:` override.

## Files

- `scripts/runtime-board/board.sh` — thin CLI wrapper around
  board-tui-mcp tools (or just `mcp call ...`) for operator
  shell convenience.
- (option A) patch in fork or upstream PR to board-tui-mcp:
  publish `board.tasks.<skill>.<state>` after each file mutation.
  Auth via env (`TEAM_ALPHA_NATS_URL`, `TEAM_ALPHA_BOARD_USER`).
- (option B) `mcp-server/src/team_alpha_mcp/board_wrapper.py` —
  `board_create / board_move / board_update` MCP tools that call
  board-tui under the hood, then publish.
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
