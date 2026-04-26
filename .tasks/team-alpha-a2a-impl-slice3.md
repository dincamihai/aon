---
column: Backlog
created: 2026-04-26
order: 140
---

# A2A on NATS — implementation slice 3 (umbrella)

Closes the MVP. After slice 3, every existing substrate flow has
an A2A counterpart in AUDIT, and the streaming + cancel primitives
work end-to-end.

## Subcards

| order | card | what |
|---|---|---|
| 141 | `team-alpha-a2a-sim-10-streaming.md` | streaming chunks via `.message`; sim 10 |
| 142 | `team-alpha-a2a-sim-11-cancel.md` | cancel signal + worker handler; sim 11 |
| 143 | `team-alpha-a2a-dual-write-cutover.md` | existing tools also emit A2A events |

## Out of slice 3 (post-MVP)

- Bouncer service.
- HTTP+SSE bridge.
- Multi-account / multi-org federation.
- JWT migration (card 70).

## Acceptance

- [ ] All three subcards complete + smokes/sims green.
- [ ] AUDIT contains a 1:1 A2A status event for every substrate
      lifecycle event (claim → working, blocked → input-required,
      done → completed, parked → input-required reason="preempted").
- [ ] No regression in slice 1+2 (smokes 17 / 17b / 18-22, sim 09).

## Refs

- `team-alpha-a2a-investigation.md` — parent decision card.
- `team-alpha-a2a-impl-slice2.md` — slice 2 cards.
