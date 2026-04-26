---
column: Backlog
created: 2026-04-26
order: 215
---

# Card 215 — Multi-role task cards (lead / workers / pm / reviewer)

## Why (rough)

A real task often needs more than one role:

- Implementation worker (priya for terraform, lin for ui, etc.).
- Lead / architect to set direction or unblock decisions.
- PM (maya) to coordinate, track, escalate.
- Reviewer (a peer specialist) before merge.

Today the runtime board (card 213) supports a single `target:` or
single skill match. Real work isn't single-target.

## Sketch

Card frontmatter declares roles needed:

```yaml
---
column: Backlog
skill: terraform
roles:
  lead:     priya          # auto-assigned via skill match if absent
  workers:  [priya, raj]   # multiple OK; or open by skill
  pm:       maya
  reviewer: any-of:[priya, diego]   # constraint, not a fixed pick
---
```

Each role is a slot. Agents claim slots they're advertised for via
a new MCP tool `board_claim_role(slug, role)`. board-tui-mcp /
team-alpha-mcp publishes `board.tasks.<skill>.role_claimed
{slug, role, by}`. PM (maya) sees claims accumulate in her Monitor.

Card progresses through states only when minimum roles are filled
(e.g. lead + at least one worker). Otherwise stays Backlog with a
"waiting on roles: [...]" annotation.

## Open brainstorm questions

- Hard slots vs. soft slots: must lead be one named role, or can
  any agent volunteer? Probably soft for v1, hard for production
  workflows.
- Cross-card linking: one card spawns subcards for parallel
  workstreams. Parent slug → child slugs, status rolls up.
- Reviewer round-robin vs. agent self-selection. Probably
  self-select with maya as tiebreaker.
- A2A side: how does dispatch work when there are multiple
  workers? `a2a_send_task` becomes per-slot. Or a new
  `a2a_send_task_multi` that targets a list, opens a parent
  task_id that fans out children.
- Lifecycle: card.column transitions from Backlog → "Roles
  Filling" → In Progress → Review → Done. board-tui needs
  custom columns or a single `column` field with state machine.
- Role-specific instructions in card body: `## Lead`, `## Workers`,
  `## Reviewer` sections so each role only reads its own
  responsibility.

## Out of scope (now)

- Implementation. This is a brainstorming placeholder. Revisit
  after card 213 (single-role) is solid in production use.
- ADR. May warrant one once design solidifies.

## Refs

- Card 213 — single-role runtime board (foundation).
- Card 214 — worker isolation (multi-role amplifies the
  isolation question — multiple containers per task).
- saas team's actual workflow — pitches → cards → multi-person
  sprints. Closest existing pattern.
