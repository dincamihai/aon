---
column: Done
created: 2026-04-25
order: 20
---

# docker-compose for team-alpha NATS substrate

Single-node compose for dev + per-host compose for multi-node deploy.

## Scope

- One service: `nats` (image `nats:latest`).
- Mounts `./nats/nats-server.conf` and `./nats/auth.conf` read-only.
- Named volume `nats_data` → `/data` for JetStream.
- Ports: `8080` (websocket), `4222` (client), `8222` (monitor), `6222` (cluster).
  Bind all to `0.0.0.0` since multi-host (not loopback like membrain POC).
- `restart: unless-stopped`.
- Optional second service `validator` (placeholder image, comment out for now —
  see `validation-gateway.md` future card).

## Files

- `docker-compose.yml` — at repo root.

## Acceptance

- [ ] `docker compose config` validates clean.
- [ ] `docker compose up -d nats` starts cleanly with sample `auth.conf`.
- [ ] `nats --server nats://<host>:4222 --user maya --password <pw> server check connection` succeeds.
- [ ] JetStream visible at `http://<host>:8222/jsz`.
- [ ] Volume persists across `docker compose down && up` (stream survives).
