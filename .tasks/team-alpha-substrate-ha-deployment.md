---
column: Backlog
created: 2026-04-26
order: 222
---

# Card 222 — Substrate HA: take admin laptop out of the critical path

Today the substrate runs on the admin's laptop + cloudflared
tunnel (Card 221 setup). If the laptop sleeps, loses wifi, or
the admin closes it, the entire team session stops. Fine for
a one-day workshop, not fine as the team starts depending on
team-alpha for routine work.

This card encodes the **migration sequence** — three stages, each
building on the previous, each removing one layer of fragility.
Stage N+1 starts only when Stage N is comfortable.

## Migration sequence

### Stage 1 — Today (Card 221)

```
admin laptop:
  ├─ nats-server (local)
  └─ cloudflared → wss://nats.<domain>

colleague laptops: clients only
```

- **SPoF**: admin laptop. Sleep / wifi flap / close = team down.
- **Cost**: $0.
- **Effort**: shipped (Card 221).
- **Use until**: team-alpha is still experimental; admin happy to babysit.

### Stage 2 — Off-laptop hub (single)

Move the substrate off the admin laptop to one stable hub. Still
single-instance — but it's a server, not a laptop.

```
hub (single nats-server somewhere stable):
  ├─ Synadia Cloud (managed)  ← recommended
  ├─ OR EC2 t3.micro w/ Elastic IP
  └─ wss://nats.<domain>

colleague laptops: clients only
```

- **SPoF**: single hub. Hardware / network / region fault = team
  down. Synadia's managed instance is more reliable than your
  laptop but still single-region in free tier.
- **Cost**: Synadia free tier (covers small team) OR ~$8/mo EC2.
- **Effort**: half a day. Migrate `nats/auth.conf` → NSC JWT
  (existing card `nsc-jwt-migration.md`). Push creds to Synadia
  or stand up EC2.
- **Use until**: hub uptime starts hurting. Realistically months
  before this becomes a real problem for a small team.

### Stage 3 — Hub cluster + per-laptop leaf nodes

Real HA. Hub becomes a 3-node cluster (Synadia auto, or
self-hosted EKS / 3 EC2s). Each laptop runs a tiny leaf
nats-server bridging to the cluster.

```
HUB CLUSTER (R=3 JetStream)
   │   │   │
   ▼   ▼   ▼
 leaf  leaf  leaf …    (one per laptop)
   │     │     │
 agent agent agent     (each agent → localhost:4222)
```

- **SPoF**: none for normal operation. Hub region outage = leaves
  run isolated locally; flush on reconnect. Laptop offline = its
  own leaf keeps serving the agent.
- **Cost**: Synadia paid tier, or self-hosted ~$25/mo (3× t3.micro
  / EKS). Plus per-laptop leaf install (free, but onboarding
  friction).
- **Effort**: 1–2 weeks. Two parallel tracks:
  - Hub: stand up cluster (Synadia / EKS / 3-node EC2).
  - Leaf: investigate per Card 75 (JetStream mirroring, KV
    staleness, subject filtering, account model). Then add
    `bash scripts/install-leaf.sh` to the joiner flow.
- **Use until**: forever (or until requirements change radically).

## Sequencing rules

- **Never skip Stage 2.** Going laptop → cluster directly couples
  the NSC migration with HA infra, doubling the risk surface.
- **Stage 3 has two tracks** that can land in either order:
  - Hub cluster first (no leaf changes; existing clients keep
    working) lets the hub harden under real load.
  - Leaf-node investigation can complete on Stage 2's single
    hub — leaves talk to a single hub fine. The investigation
    output (Card 75) is the gate, not the cluster.
- **Trigger to advance**: when Stage N's failure mode actually
  bites the team (admin overnight outage at Stage 1, hub
  hiccup at Stage 2). Don't pre-empt; let pain drive promotion.

## Acceptance per stage

### Stage 2 acceptance

- [ ] Substrate URL stable across admin laptop reboots.
- [ ] All 5 worker roles + admin connect from outside admin's
      network.
- [ ] AUDIT stream survives the cutover (or explicit decision
      to start fresh, recorded here).
- [ ] NSC JWT credentials replace plain `auth.conf` passwords.
- [ ] `nats/auth.conf` removed from the admin laptop.

### Stage 3 acceptance

- [ ] Hub component loss does not stop a session for ≥30 min
      (leaves keep agents alive; admins notice via alert, not
      session crash).
- [ ] Per-laptop leaf installs cleanly via `scripts/install-leaf.sh`.
- [ ] Offline-then-reconnect cycle: agent keeps working
      disconnected, AUDIT catches up on reconnect, no message
      loss measured against control trace.
- [ ] Card 75 investigation closed (JetStream propagation, KV
      staleness window, subject filtering, account model — all
      decided).

## Open questions (revisit at each stage transition)

- **Stage 2**: Synadia free-tier limits vs. team size? Compliance /
  data-classification — can audit data live on Synadia infra?
- **Stage 3**: hub cluster on Synadia (managed, simple) vs.
  self-hosted (EKS / 3× EC2 — more control, more ops)?
  Multi-region? Split-horizon (some streams on-prem, some cloud)?

## Files (per stage when picked)

- Stage 2 (Synadia): `nsc/<context>` operator/account/users, JWT
  push to Synadia, `nats/synadia.conf` for migration helpers.
- Stage 2 (EC2 fallback): `infra/ec2/cloud-init.yaml`, security
  group, EIP.
- Stage 3 (hub cluster): `infra/eks/nats-helm-values.yaml` OR
  `infra/cluster/3-node-ec2.tf`, ingress, cert-manager.
- Stage 3 (leaf): `scripts/install-leaf.sh`, sample
  `~/.config/nats-leaf/leaf-server.conf`.

## Refs

- Card 10 (Done) — single-host config w/ cluster stub.
- Card 70 — VPN binding (orthogonal; Synadia removes need).
- Card 75 — leaf-node investigation, **prerequisite for Stage 3**.
- Card 160-series — A2A client-side HA; complementary, not a
  replacement.
- `nsc-jwt-migration.md` — **prerequisite for Stage 2**.
- Card 221 — current cloudflared-from-laptop setup (Stage 1).

## (legacy survey — kept for reference; superseded by sequence above)

### A — EKS w/ NATS Helm chart

- 3-replica `nats-server` StatefulSet, JetStream R=3.
- ALB / NLB w/ TLS for external clients (websocket on 443).
- Existing cluster routes config (Card 10) plugs in directly.
- Cost: existing EKS cluster (~$73/mo control plane + nodes) +
  3 small pod replicas. Cheapish if EKS already in use; expensive
  if standing up just for this.
- Effort: Helm install, ingress, cert-manager. Half a day if
  comfortable with EKS, full day if not.
- Pro: real HA, integrates with company AWS ops, auditable.
- Con: most operational overhead.

### B — Synadia Cloud (NGS, managed)

- https://www.synadia.com/cloud — Synadia (NATS company) hosts
  the cluster. Multi-region.
- Free tier covers small teams (limits per their pricing page).
- Migrate `nats/auth.conf` users → NSC JWT (Card on
  `nsc-jwt-migration.md` already exists).
- Effort: half a day. Mostly NSC migration, minimal infra.
- Pro: zero infra to run; HA + multi-region for free.
- Con: external dependency, less control. Egress data charges if
  team grows large.

### C — Fargate task + NLB

- 1 (or 3) Fargate tasks running `nats:latest`, behind an NLB
  with Elastic IPs for stable URL.
- JetStream R=N if multi-task.
- Cost: ~$10/task/mo + ~$16 NLB.
- Effort: a few hours; ECS task def, NLB target group, route 53.
- Pro: no laptop dependency, AWS-native.
- Con: still kinda a SPoF if 1 task; full HA = 3 tasks +
  shared EFS or just JetStream R=3 + sticky.

### D — Single EC2 t3.micro w/ Elastic IP

- 1 nats-server, systemd, restarts on host reboot.
- Free-tier first year, ~$8/mo after.
- Not HA — host loss = downtime.
- Effort: 1 hour. Mirrors current host setup.
- Pro: cheapest, simplest.
- Con: still a SPoF, just not the laptop.

### E — Leaf-node mesh (Card 75)

- Each laptop runs a small leaf nats-server, bridges to a hub.
- Hub still needs to live somewhere (one of A-D).
- Useful for offline-first; not a hub-replacement.
- Pair with one of A-D as the hub option.

