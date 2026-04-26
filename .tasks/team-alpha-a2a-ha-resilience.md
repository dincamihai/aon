---
column: Backlog
created: 2026-04-26
order: 160
---

# A2A HA + reconnect resilience (umbrella)

MVP slices 1-3 ship a single-instance-per-role A2A surface.
Production agents will run as N≥2 instances, may restart, may
disconnect briefly. Six gaps surfaced during slice-3 review;
each addressed by its own subcard.

Order matters — subcards stack:
- 161 first (queue dedup + inflight CAS) — cheapest, fixes
  duplicate-work today.
- 162 (catchup) — restores state-on-rejoin without the rest.
- 163 (durable send) — biggest architectural lift; depends on
  161 + 162 done.
- 164 (lease + heartbeat) — auto-recovery; depends on 163.
- 165 (watcher leader) — orthogonal but required for >1 ops box.
- 166 (retention + ordering doc) — pure docs, ship anytime.

## Subcards

| order | card | what |
|---|---|---|
| 161 | `team-alpha-a2a-ha-queue-groups.md` | NATS queue subscriptions + KV-inflight CAS |
| 162 | `team-alpha-a2a-ha-catchup-tool.md` | `agent_catchup(role, since)` w/ summary mode |
| 163 | `team-alpha-a2a-ha-durable-send.md` | tasks.send via workqueue stream, survives total outage |
| 164 | `team-alpha-a2a-ha-ownership-lease.md` | TTL lease + heartbeat in inflight KV → auto-recover crashed mid-work |
| 165 | `team-alpha-a2a-ha-watcher-leader.md` | KV-based leader election for coordinator-watcher |
| 166 | `team-alpha-a2a-ha-retention-and-ordering.md` | AUDIT/source retention alignment + cross-stream ordering caveat doc |

## Acceptance (whole umbrella)

- [ ] All 6 subcards complete + smokes/sims green.
- [ ] One soak test: kill / restart instances mid-traffic; AUDIT
      shows no lost events, no duplicates, recovery within
      heartbeat TTL.
- [ ] Live test (card 151 or 152) confirms agent UX unchanged from
      MVP after HA layer added.

## Out of scope (post-HA)

- Multi-account / multi-org federation (needs JWT first; card 70).
- HTTP+SSE bridge.
- Geo-distributed write-quorum (single cluster only).

## Refs

- `team-alpha-a2a-impl-slice3.md` — MVP closed; this umbrella
  hardens it for production.
- `team-alpha-a2a-investigation.md` — original substrate decisions.
