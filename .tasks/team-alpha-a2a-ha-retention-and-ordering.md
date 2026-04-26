---
column: Backlog
created: 2026-04-26
order: 166
---

# Retention alignment + cross-stream ordering doc

Two pure-doc gaps surfaced during slice 3 review. Cheap to ship,
high-leverage when an agent or operator hits the edges.

## Issues

### 1. Retention asymmetry

- Source streams (TASKS, LEARNING, RESULTS, EVENTS, A2A_TASKS):
  max-age = 30d.
- AUDIT (sources from above): max-age ≈ 1y (from
  `ensure_audit_stream`, set to 31536000000000000 ns).

So AUDIT outlives sources by ~10x. Replay tools that hit AUDIT
work for 1y; replay tools that hit source streams (rare today)
fail past 30d. catchup tool (card 162) reads AUDIT only — fine.

### 2. Cross-stream ordering

AUDIT is a sourced stream — events arrive in AUDIT-arrival-time
order, NOT original-publish-time order. Two events published 100ms
apart on different source streams may appear in AUDIT in any
order, depending on per-source mirror lag (typically ms, but
unbounded under load).

This means replay tools that pull from AUDIT and sort by AUDIT
sequence number give an order that is **mostly** correct but not
guaranteed. catchup tool (card 162) sorts by event `ts` field
inside the payload — closer to truth, still subject to clock skew
across publishers.

## Deliverables

### 1. Retention alignment

Decide: bump source streams to 1y (storage cost, but consistent),
OR document as-is (cheap). Recommend **document as-is**: source
streams as workqueue/limits w/ 30d are sized for ops needs, not
replay; AUDIT is the replay surface.

### 2. Doc updates

`MODEL.md` §"What you'd actually build" → add a §"Retention and
ordering caveats":
- AUDIT = canonical replay surface, 1y limit.
- Source streams = operational, 30d limit.
- Replay tools (recent_events, agent_catchup) MUST hit AUDIT not
  sources.
- Cross-stream ordering: AUDIT seq order ≈ wall-clock order to
  ~ms accuracy under normal load; sort by payload `ts` for
  agent-visible ordering; never rely on AUDIT seq for causality.
- Causality between two events on the same source stream IS
  preserved (per-stream FIFO).

`team_alpha_mcp/a2a/__init__.py` docstring gets a 5-line note
referring to MODEL.md.

### 3. Doc smoke

`scripts/smoke/32-retention-doc.sh` — trivial:
- assert AUDIT stream max_age ≈ 31536000s ± 10%
- assert each source stream max_age ≤ 30d
- catches drift if someone bumps retention without doc update

## Acceptance

- [ ] MODEL.md updated.
- [ ] Module docstrings reference the caveat.
- [ ] Smoke 32 green.

## Refs

- `team-alpha-a2a-ha-resilience.md` — umbrella.
- `team-alpha-a2a-ha-catchup-tool.md` (162) — ordering note links
  back here.
