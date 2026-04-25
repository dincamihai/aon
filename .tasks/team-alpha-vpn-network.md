---
column: Backlog
created: 2026-04-25
order: 70
---

# Network — bind NATS to company VPN, lock down public ifaces

Try company VPN first before considering tailscale or public TLS.

## Scope

NATS server reachable only from corp VPN. No public exposure. All six users
connect over VPN.

## Steps

1. **Identify VPN iface on the host**: usually `tun0` / `utun*` (macOS) /
   `wg0`. Capture the VPN-assigned IP into `nats/network.env` (gitignored).
2. **Bind NATS to VPN IP only**, not `0.0.0.0`:
   - `host: <vpn-ip>` for client (4222), websocket (8080), monitor (8222),
     cluster (6222) in `nats-server.conf`.
   - Or in `docker-compose.yml`: `ports: ["<vpn-ip>:4222:4222", ...]`.
3. **Host firewall** belt-and-suspenders: iptables/pf rule denying 4222/8080/
   8222/6222 on any non-VPN iface.
4. **DNS**: register an internal name (e.g. `nats.team-alpha.corp`) → VPN IP, so
   user creds reference name not raw IP. Coordinate w/ IT.
5. **Connectivity matrix test**: from each team member's laptop on VPN, run
   `nats --server nats://nats.team-alpha.corp:4222 --user <name> --password <pw>
   server check connection`. All six pass.
6. **Off-VPN test**: same command without VPN must fail (connection refused /
   timeout). Verify from at least one external network.
7. **Document** in `docs/network.md`: VPN profile required, DNS name, ports,
   troubleshooting (split-tunnel, MTU, DNS leakage).

## Cluster note (multi-host)

If running >1 NATS node: cluster routes (6222) also bind VPN iface. Routes list
peers by VPN DNS name, not public DNS. Add to `cluster {}` block in
`team-alpha-nats-config.md`.

## Acceptance

- [ ] `ss -tlnp` (or `lsof -iTCP -sTCP:LISTEN`) shows NATS ports bound to VPN IP
      only, not `0.0.0.0`.
- [ ] Off-VPN connection refused / times out (verified from external network).
- [ ] All six users connect successfully when on corp VPN.
- [ ] Internal DNS name resolves on VPN, fails off-VPN.
- [ ] `docs/network.md` written w/ runbook for new joiner getting on the bus.

## Fallback

If corp VPN proves unworkable (split-tunnel breaks NATS, IT denies port, etc):
- Plan B: tailscale tailnet (cheap, fast). Add separate card.
- Plan C: public NATS + TLS + NSC/JWT. Promote `nsc-jwt-migration.md` to now.
