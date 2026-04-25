---
column: Backlog
created: 2026-04-25
order: 1000
priority: deferred
---

# Migrate auth: user+password → NSC / JWT (decentralized accounts)

**Deferred** — pick up only when one of these triggers:
- Adding a second team / account boundary needed.
- Need credential rotation without server restart.
- Need revocation of a single user without redistributing `auth.conf`.
- Exposing NATS to the public internet (per-user signed creds > shared password file).

## Scope

Replace static `accounts {}` / `users {}` block in `nats-server.conf` with
operator-signed JWT auth via `nsc`.

Steps:

1. `nsc add operator team-alpha-op` + push to a local resolver dir.
2. `nsc add account team-alpha`.
3. For each of the six users, `nsc add user <name>` with permissions translated
   from current `nats-server.conf` (allow/deny lists become JWT claims).
4. Output `.creds` file per user → distribute via secret manager.
5. `nats-server.conf`: replace `authorization {}` block with `operator: <jwt>`
   and `resolver: { type: full, dir: ./resolver }`.
6. Update `bootstrap.sh` to use admin `.creds` instead of `--user/--password`.
7. Update `docker-compose.yml` to mount resolver dir.
8. Doc rotation runbook: `nsc edit user <name> ...` + `nsc push`.

## Acceptance

- [ ] `team-alpha-nats-config.md` deliverables ported to NSC equivalents.
- [ ] All six users connect with `.creds` file, permissions verified by attempted
      publish/subscribe on disallowed subjects (must reject).
- [ ] Revoking one user (`nsc revocations add-user`) takes effect without
      restarting nats-server.
- [ ] Old user+password block fully removed from `nats-server.conf`.
- [ ] Cluster routes still work post-migration (multi-host).

## References

- [MODEL.md](../MODEL.md) — permission contracts that JWT claims must preserve.
- [team-alpha-nats-config.md](team-alpha-nats-config.md) — source-of-truth permission
  mapping to translate.
- NATS docs: https://docs.nats.io/running-a-nats-service/configuration/securing_nats/auth_intro/jwt
