---
column: Backlog
priority: medium
discovered_by: rona (exploratory)
---

# resolve-env legacy per-role fallback doesn't export KV bucket + work repo

When team env at `~/.aon/teams/<team>/<team>.env` is absent, readers fall
back to per-role `~/.aon/teams/<team>/creds/<role>.env`. The per-role .env
has `AON_KV_BUCKET` and `AON_WORK_REPO` set, but `resolve-env` legacy
path doesn't export them — only `AON_NATS_URL`.

## Acceptance
1. resolve-env with legacy per-role .env only exports same vars as team env.
2. MCP server with legacy only doesn't hit BucketNotFoundError.
3. Backward compat preserved.
