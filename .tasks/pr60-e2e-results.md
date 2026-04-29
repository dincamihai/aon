---
column: Done
priority: medium
created: 2026-04-29
owner: rona
---

# PR #60 e2e results — doctor SSM conditional + role-brief step 6

Branch: `sun/fix-doctor-ssm-conditional-and-role-brief` commit `9b9371d`

## Results (round 1)

| Case | Result | Notes |
|------|--------|-------|
| 1 `aon doctor` local-only (no [aws] in aon.toml): no AWS/SSM warnings | PASS | Zero AWS/SSO/SSM lines in output; "no active SSM tunnel" is separate tunnel-state check (expected) |
| 2 `aon doctor` with [aws] instance_id set: AWS checks fire | PASS | aws CLI v2 ✓, session-manager-plugin ✓, SSO expired warning fires (SSO not active — correct) |
| 3 `get_role_brief()` serves new verify-before-implement step 6 | PASS | `aon prompts show rona` renders step 6: "Verify before implementing: check if already fixed in main" |

## Fix verified

Doctor: `_aws_instance_id="$(aon_toml_get ... aws instance_id)"` gates entire
AWS block. No `[aws]` section → empty string → block skipped entirely.

Role-brief template: step 6 added between "Claim" and "Work". Steps 6→7→8
renumbered correctly.

## Verdict

**Ready to merge.** All 3 cases pass.
