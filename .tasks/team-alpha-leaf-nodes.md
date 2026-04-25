---
column: Backlog
created: 2026-04-25
order: 75
---

# Investigate leaf-node deployment — per-laptop substrate, offline-first

NATS leaf nodes let each member's machine run a tiny nats-server that bridges
to a corp hub. People work disconnected (plane, hotel wifi, no VPN) and
resync on reconnect. Also enables solo/sabbatical mode where someone works
alone without polluting team bus.

## Premise

Today: one cluster on corp VPN host. Network drops or laptop offline →
interaction model breaks.

Future: each laptop runs a leaf nats-server. Agent connects to
`localhost:4222`. Leaf bridges to corp hub on `:7422`. Connected → subjects
propagate both ways. Disconnected → leaf still serves local agent;
publishes queue (JetStream local mirror); on reconnect, leaf flushes.

## What this enables

- **Offline work**: agent claims, progresses, parks; offline 3h; reconnect
  flushes everything to hub, AUDIT catches up, no data loss.
- **Local resilience**: VPN flap doesn't kill session.
- **Lower latency**: agent ↔ leaf = localhost. Leaf ↔ hub = async WAN hop.
- **Solo / sabbatical mode**: someone deep in a refactor publishes locally
  without hub seeing in-progress churn. Manual flush when ready.

## Investigation questions (no implementation yet)

1. **Account model**: same as hub or bridged? Per-user-per-laptop accounts?
   NSC integration?
2. **JetStream propagation**: streams on hub + mirror on leaf? Or core-sub
   bridge only? Implication for AUDIT continuity.
3. **KV bucket access**: live or reconnect-only? Read-staleness window?
4. **Subject filtering**: leaf can deny outbound subjects. Syntax?
5. **Auth**: leaf-to-hub shared secret vs JWT-signed leafnode creds.
6. **Failure modes**: leaf JS disk full? Reconnect storms hub? Back-pressure?
7. **Solo mode**: agent flag to stop syncing? Native or custom switch?
8. **Per-laptop install footprint**: brew, launchd, systemd.
9. **Conflict resolution**: KV LWW for `state.agent.<role>.load` — OK?
10. **Cost**: every laptop running JS adds ops overhead. Worth it?

## Files

- `docs/leaf-nodes-investigation.md` — answers + recommended path
- `nats/leaf-config-example.conf` — template
- (optional) `scripts/leaf-onboard.sh` — install + configure local leaf

## Acceptance

- [ ] Doc answers all 10 with NATS doc references.
- [ ] Recommendation grounded in observed single-cluster failures after
      2-4 weeks real team use: implement now / defer 6 months / never.
- [ ] If yes: subsequent card scopes implementation.
- [ ] If no: doc records reason so future engineers don't relitigate.

## Out of scope

- Implementation (this card = investigation only).
- Multi-region gateways / super-cluster (separate card if needed).

## Refs

- NATS leaf nodes: https://docs.nats.io/running-a-nats-service/configuration/leafnodes
- card 70 (VPN): leaf still benefits from VPN; public TLS leaf-to-hub also
  viable.
- card 1000 (NSC/JWT): leaf creds map cleanly to JWT model.
- card 90 (human-availability): leaf-mode pairs with `status:offline` —
  agent hub-offline but still productive locally.
