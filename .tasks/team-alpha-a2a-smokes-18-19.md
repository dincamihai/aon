---
column: Backlog
created: 2026-04-26
order: 135
---

# A2A smokes 18 (discovery) + 19 (ACL coverage)

Slice 1's smoke 17 covers the basic round-trip + ACL allows/denies
on send + status. Slice 2 adds discovery and broader ACL coverage.

## Smoke 18 — discovery

`scripts/smoke/18-a2a-discovery.sh`:

1. Sysadmin pre-publishes each role's card to
   `a2a.discovery.<role>` (slice 2 cron / on-startup task; for the
   smoke we just publish from the .json).
2. Assert max-msgs-per-subject 1 enforced — publish twice, only
   latest retained.
3. Assert each role can pub their own discovery subject; can NOT
   pub another role's discovery subject.
4. Assert non-worker (Maya) can read all discovery subjects.
5. JSON-parse the retrieved card, assert `name == role`, `version`
   present, `skills` non-empty for workers.

## Smoke 19 — A2A ACL coverage

`scripts/smoke/19-a2a-acl.sh`:

Comprehensive ACL matrix:
- Each worker on own `a2a.<self>.tasks.>` — pub allowed, sub allowed
  on `.send` + `.cancel`.
- Each worker on another worker's `a2a.<other>.tasks.>` — pub denied.
- Maya on `a2a.*.tasks.send` — allowed.
- Non-Maya workers on `a2a.*.tasks.send` (any other role) — denied.
- All workers on `a2a.*.tasks.*.cancel` (other roles) — denied.
- Maya on `a2a.discovery.>` — pub + sub allowed.
- Workers on own `a2a.discovery.<self>` — pub allowed.
- Workers on other `a2a.discovery.<other>` — pub denied.

## Acceptance

- [ ] Smoke 18 green; max-msgs-per-subject 1 verified.
- [ ] Smoke 19 green; full matrix.
- [ ] Both included in `scripts/smoke/run-all.sh` (auto-picked).

## Refs

- `team-alpha-a2a-impl-slice2.md` — umbrella.
- `team-alpha-a2a-impl-slice1.md` — ACL pattern this verifies.
