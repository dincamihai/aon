---
date: 2026-04-29
author: rona
type: standup-retro
---

# Standup + Retro — rona — 2026-04-29

## Shipped

- **PR #55** (fix-mcp-healthcheck-auth-fail) — 4 rounds, all 5 cases PASS. ExceptionGroup unwrap in `main()` fixed traceback on auth/unreachable error paths. Merged.
- **PR #57** (fix-stale-cursor-deletion-f5) — 4/4 cases PASS. Roster-aware cursor pruning via `_hook_roster_from_toml()`. Peer cursors no longer wiped on session start. Merged.
- **PR #58** (fix-f2-acl-drift) — 6/6 cases PASS. `--role tim` in `set-nats-url` now probes with `tim.creds`. ACL drift detection + `--apply-acl-drift` working. Caught real pre-existing drift on `mid` user (manager ACL changed) and fixed it in place. Merged.
- **PR #59** (fix-resolve-env-kv-fallback) — 4/4 cases PASS. `AON_KV_BUCKET` derived from `aon.toml` when team env absent. MCP `BucketNotFoundError` on legacy path eliminated. Merged.
- **anon-connect-smoke** (main branch) — 3/3 cases PASS. `anon.creds` at correct path, pub allow correct, `aon connect` publishes join request without permissions violation, restricted subjects blocked. Bug2+D2 confirmed fixed.

## Blocked / Follow-up

None.

## Retro

### What went well

- Round-trip on PRs was fast — 4 rounds on PR #55 but each fix was targeted and correct; PR #57–59 cleared in round 1.
- `--apply-acl-drift` caught real production drift on `mid` user during PR #58 testing — not a synthetic case. Feature proved its value immediately.
- Test isolation (temp env files, fake HOME dirs for cursor tests) worked cleanly without touching live state.

### Could be better

- `aon set-nats-url` corrupted `workers.env` twice during testing — BITS must come first, flags after, but the help text doesn't make this obvious. Consider a positional arg guard or clearer usage string.
- `aon sub` (Python CLI) exits 1 with no useful error message — had to fall back to raw `nats` CLI with creds for probe capture in PR #58. Investigate why the Python CLI fails silently.
- `aon doctor` SSM tunnel warning fires even on fully local setups — caused a false "NATS unreachable" assumption at session start. Warning should only fire if instance_id is configured in `aon.toml`.
