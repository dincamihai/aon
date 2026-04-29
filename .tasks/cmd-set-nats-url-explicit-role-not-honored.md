---
column: Done
priority: medium
created: 2026-04-29
source: joana audit (F2) on 4d5911b..62dc26d
---

# `aon set-nats-url --role NAME` uses `_first_role` instead of explicit role

Commit `eb31c8e` (`fix(aon): move .env from per-role to per-team`).

`bin/aon:2282-2287` — when `--role NAME` is specified, code correctly finds which teams contain that role, but then picks `_first_role` via `*.creds` glob for `_aon_apply_nats_url`. If a team has multiple `.creds` files, `_first_role != explicit_role` → handshake probe uses wrong creds.

## Fix

Use `${explicit_role}` when set; only fall back to `_first_role` when `--role` is omitted.

## Acceptance

1. `aon set-nats-url --role tim BITS` always probes with `tim.creds`.
2. Existing single-role-per-team behavior unchanged.
3. Add a regression case to `scripts/aon-tests/` covering the multi-role-per-team path.
