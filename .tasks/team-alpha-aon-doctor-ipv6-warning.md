---
column: Backlog
created: 2026-04-27
order: 245
priority: low
parent: team-alpha-meta-aon-cli
---

# Card 245 — `aon doctor` warns on `localhost` IPv6-first resolution

Trial caught: `nats --server nats://localhost:4222 …` resolved
`[::1]:4222` first, container only listens on IPv4 → `failed`.
Misleading.

## Goal

Two changes:

1. `templates/aon.toml.example` default `nats.url` =
   `nats://127.0.0.1:4222` (not `localhost`).
2. `aon doctor` warns when `nats.url` host is `localhost` AND
   the host's `ahost` lookup returns an IPv6 first record AND
   the NATS container does not bind `[::]` — surface the likely
   confusion before the operator hits it.

## Acceptance

- New team repos default to `127.0.0.1`.
- `aon doctor` on a misconfigured repo emits one yellow warning
  line: `nats.url uses localhost; prefer 127.0.0.1 or bind nats
  on [::]`.

## Why

Twice burnt on the trial. Cheap fix.
