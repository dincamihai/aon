---
column: Backlog
created: 2026-04-26
order: 130
---

# A2A on NATS — implementation slice 2 (umbrella)

Builds on `team-alpha-a2a-impl-slice1.md` (committed 4fe57eb).
Slice 2 closes the end-to-end loop, restores MODEL.md alignment
(generalist self-route), and integrates the watcher.

Each deliverable lives in its own subcard. This card tracks the
slice-2 release as a whole.

## Subcards

| order | card | what |
|---|---|---|
| 131 | `team-alpha-a2a-worker-accept-loop.md` | worker auto-accepts `tasks/send` on `a2a.<self>.tasks.send` |
| 132 | `team-alpha-a2a-pull-push-hybrid.md` | `dispatch_mode` field; pull mode reuses `board.tasks.<d>.pending` |
| 133 | `team-alpha-a2a-watcher-integration.md` | watcher detects stale + duplicate-dispatch on `a2a.>` |
| 134 | `team-alpha-a2a-sim-09-dispatch.md` | sim scenario 09 — full A2A dispatch lifecycle |
| 135 | `team-alpha-a2a-smokes-18-19.md` | smoke 18 discovery + 19 ACL coverage |
| 136 | `team-alpha-a2a-kv-skills-deprecation.md` | drop KV `agent.<role>.skills`; migrate readers |

## Out of slice 2 (slice 3+)

- Bouncer service (server-side per-skill ACL).
- HTTP+SSE bridge (external A2A interop).
- Sim scenarios 10 (streaming) + 11 (cancel) — bundle with HTTP work.
- Full dual-write cutover from `board.>` broadcast to A2A directed
  dispatch (this slice keeps both flows; slice 3+ flips defaults).

## Acceptance (whole slice)

- [ ] All six subcards complete + green smokes/sims.
- [ ] No regression in slice 1 smokes (17) or pre-existing 1–16.
- [ ] MODEL.md updated with hybrid dispatch + KV-skills deprecation note.

## Refs

- `team-alpha-a2a-investigation.md` — parent decision card.
- `team-alpha-a2a-impl-slice1.md` — slice 1 (cards + ACL + streams + dispatcher).
