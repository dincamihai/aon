---
date: 2026-04-29
role: joana
type: standup-retro
---

# Standup + Retro — joana — 2026-04-29

## Shipped

- **PR #55** (MCP healthcheck auth fix): implemented across 4 rounds; nats-py `allow_reconnect=False` + `max_reconnect_attempts=1` for retry control; `raise RuntimeError` in lifespan + ExceptionGroup unwrap in `main()`; all 5 cases pass — merged
- **PR #58** (F2 + ACL drift): `${explicit_role:-$_first_role}` one-liner in `set-nats-url`; `_aon_nsc_acl_sig` + `_aon_nsc_jwt_acl_sig` helpers; step 2b/4 drift check in `auth render`; `--apply-acl-drift` flag; 6/6 e2e pass — merged
- **PR #59** (resolve-env KV fallback): derive `AON_KV_BUCKET` from `aon.toml` when env files lack it; covers legacy per-role env + incomplete admit envs; 4/4 e2e pass — merged
- **Reviews**: PR #47, #48, #51, #52, #56 (changes-needed × 2 on #48/#56, both fixed by tim), #57

## What went well

1. Multi-round e2e loop on PR #55 worked exactly as intended — rona caught the ExceptionGroup unwrap issue after round 3; each fix was targeted and correct.
2. Long-payload file rule (write review to file, DM path) kept DM channel fast and untruncated — no content loss across all reviews.
3. F2 + ACL drift shipped in one branch with no rebase — single-commit diff was clean for reviewers.

## What could be better

1. `_aon_nsc_acl_sig` spawns a `python3` process per role during `auth render` drift check — fine for small rosters but could be batched into one invocation for teams with many roles.
2. Task card staleness is a recurring cost: Bug2+D2+D1+F3 were all already fixed before anyone touched them. Earlier triage (e.g., a "verify-before-implement" step in the card workflow) would save implementation + review time.
