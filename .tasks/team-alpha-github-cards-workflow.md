---
column: Backlog
created: 2026-04-25
order: 80
---

# Task-card workflow over GitHub repo + NATS

Real work is reflected in **task cards in a GitHub repo** (similar to
`.tasks/*.md` in this repo). Workers post the work done on the card and
notify coordinator via NATS. NATS is the live signal, GitHub is the durable
artifact.

## Premise

- Cards live in a separate "work" repo (not this substrate repo).
- Each card = a markdown file with frontmatter (`column`, `assignee`,
  `claimed_by`, `pr_url`, …) — same convention as
  [task-cards skill](../../../.claude/skills/task-cards/SKILL.md).
- Worker edits + commits + pushes the card to mark progress; emits NATS
  events so the coordinator (Maya) sees state transitions in real time.
- Two-way: NATS event references card slug + git sha; coordinator can
  `git fetch` to verify and merge.

## Scope

### Conventions

- **Card claim**: worker sets `claimed_by: <role>` + `column: InProgress` in
  card frontmatter, commits, pushes to a branch `<role>/<slug>`. Then emits
  `board.tasks.<domain>.claimed` w/ `{slug, branch, sha, role}`. The
  publication is idempotent — coordinator dedupes on `slug+role`.
- **Atomic claim race resolution**: git push wins. Two workers attempting
  `claimed_by: <role>` on the same card both push to `<role>/<slug>`
  branches; coordinator on receiving the first NATS `claimed` event marks
  authoritative claim and DM-rejects later claimants. Card itself stays
  unmodified on master until first claim is acked by coordinator.
- **Work signal**: every commit on the worker's branch emits
  `board.tasks.<domain>.progress` w/ `{slug, sha, summary}`.
- **Submission**: PR opened → `pr_opened` event with PR URL. Coordinator
  reviews + merges (only Maya/Raj have merge perms in GitHub).
- **Done**: post-merge, worker emits `board.tasks.<domain>.done` and
  `board.results.<domain>.shipped` w/ merge sha + card slug.

### Race-condition tests (smoke 08+)

- `08-card-claim-race.sh` — two workers concurrently emit `.claimed` for the
  same slug. Coordinator must pick exactly one winner and reject the other
  via DM to `agents.<loser>.inbox`.
- `09-double-work-detection.sh` — both winners proceed past claim (e.g.
  network split + DM lost). Detection: any `board.results.*.shipped` for a
  slug already shipped from another role triggers a `state.alert.duplicate`
  event Maya subscribes to.
- `10-stale-claim-gc.sh` — worker claims, never updates load for >TTL,
  coordinator emits `state.alert.stale_claim` with slug + role; human
  reviews + force-releases the card.

### Detection mechanism (always-on, not opt-in)

- A small **coordinator-watcher** process (Maya's box, or a dedicated svc)
  consumes EVENTS stream by subject `board.tasks.*.{claimed,done}` and
  `board.results.>`. Maintains a tiny in-memory map `slug → first-claimer`.
  On second-claim or duplicate-result for same slug, publishes
  `state.alert.<kind>` to `state.alert.>` (Maya is subscribed via `state.>`).
- Detection is in audit + alert, not blocking — workqueue stream already
  prevents the simple race; this catches messy real-world cases (push
  conflicts, partial network partitions).

## Files (when implemented)

- `scripts/sim/coordinator-watcher.sh` — daemon. Consumes events, maintains
  state, publishes alerts.
- `scripts/smoke/08-card-claim-race.sh`
- `scripts/smoke/09-double-work-detection.sh`
- `scripts/smoke/10-stale-claim-gc.sh`
- `docs/cards-over-nats.md` — design doc: how the substrate maps to a real
  GitHub-cards workflow, PR conventions, branch naming, dedupe rules.

## Acceptance

- [ ] All three race smoke scripts pass on a fresh stack.
- [ ] Coordinator-watcher catches a fabricated double-shipped slug within 5s
      and publishes `state.alert.duplicate`.
- [ ] Stale-claim GC fires on a synthetic agent that goes silent — alert
      includes slug + role + last-seen timestamp.
- [ ] `cards-over-nats.md` describes branch naming, claim/done flows,
      dedupe semantics; reviewed against MODEL.md for permission alignment.

## Out of scope

- Building actual GitHub Actions integration — cards-over-NATS is a
  *protocol*; the GitHub side can be added later without changing NATS.
- Replacing GitHub for storage — durability lives there, not in NATS.
