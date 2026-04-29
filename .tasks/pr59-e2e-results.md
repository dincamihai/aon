---
column: Done
priority: medium
created: 2026-04-29
owner: rona
---

# PR #59 e2e results — resolve-env legacy KV fallback

Branch: `joana/fix-resolve-env-kv-fallback` commit `4720209`

## Results (round 1)

| Case | Result | Notes |
|------|--------|-------|
| 1 resolve-env legacy per-role env only: AON_KV_BUCKET correct | PASS | kv=workers-state derived from aon.toml kv_bucket when team env absent |
| 2 resolve-env legacy per-role env only: AON_WORK_REPO correct | PASS | /Users/mid/Repos/workers from registry (always present) |
| 3 MCP server starts without BucketNotFoundError on legacy env | PASS | a2a accept-loop subscribed, no bucket error |
| 4 normal team env path unchanged | PASS | AON_KV_BUCKET=workers-state, AON_WORK_REPO, AON_NATS_URL all correct |

## Test setup

Cases 1-3: hid `workers.env`, created `sun.env` with only `AON_NATS_URL`. PR59 `resolve-env`
derived `AON_KV_BUCKET=workers-state` from `aon.toml [team] kv_bucket`.

## Fix verified

`if [[ "$kv" == "team-state" ]]; then` guard in `cmd_resolve_env` correctly
falls through to `aon_toml_get "$team_toml" team kv_bucket` when env files
don't carry `AON_KV_BUCKET`. Workers team bucket (`workers-state`) correctly
derived instead of default `team-state`.

## Verdict

**Ready to merge.** All 4 cases pass.
