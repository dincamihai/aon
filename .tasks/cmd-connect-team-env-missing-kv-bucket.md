---
column: Backlog
priority: medium
created: 2026-04-29
source: tim review (D4) on 4d5911b..62dc26d
---

# `cmd_connect`: team env file written without `AON_KV_BUCKET`

Commit `32daffe` (`feat(aon): add cmd_connect for waiting-room joiner flow`).

`bin/aon:2787` — `cmd_connect` writes the team env file with `AON_ROLE_DEFAULT`, `AON_NATS_URL`, `AON_CREDS` but omits `AON_KV_BUCKET`. After waiting-room onboarding, `aon monitor`, the MCP server, and all KV operations fail because the bucket isn't resolvable.

The legacy `cmd_join_link` path writes this var correctly; the new path does not.

Related: `.tasks/resolve-env-legacy-fallback-missing-vars.md` (Backlog).

## Fix options

a) Admin reply JSON includes `kv_bucket`; `cmd_connect` parses + writes it.
b) After creds placement, infer via `aon_toml_get ... team kv_bucket` and write.

Option (a) is cleaner — the admin already knows the bucket and avoids depending on a local `aon.toml` for the joiner.

## Acceptance

1. Team env file produced by `cmd_connect` contains `AON_KV_BUCKET=<bucket>`.
2. `aon monitor` and `aon mcp` work immediately after a fresh `aon connect`.
3. End-to-end smoke test: anon connect → admin approve → joiner runs `aon monitor` successfully.
