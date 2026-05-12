---
column: Backlog
---

# aon connect local: auto-enroll if role not in roster
## Parent
refactor-aon-cli-into-grouped-namespaces

## Context

`aon connect ROLE [WORK_REPO]` (localhost, no token) requires the role to already exist in aon.toml. But operators want walk-up joins: connect with just a name, get basic access, admin refines role later.

## Behaviour

`aon connect NAME` on localhost — if NAME not in roster:
1. Auto-add as `generalist fullstack` (same as `aon admin onboard NAME` step 1)
2. Run `aon admin reinit` to mint auth + bootstrap + render prompts
3. Complete local join (`_cmd_join_local NAME`)
4. Print: "added NAME as generalist/fullstack — operator can update kind/domain in aon.toml + run 'aon admin reinit' to change role"

If NAME already in roster → skip enroll, just join (existing behaviour).

Remote flow (`aon connect aon://TOKEN BITS`) unchanged — role is pre-assigned in token.

## Files

- `bin/aon` — `cmd_connect` local branch: check roster, call `cmd_add_role` + `cmd_reinit` if missing, then `_cmd_join_local`
- `bin/aon` — help text: update local connect description

## Verification

1. `aon connect alice` from team-aon repo, alice not in roster → alice added as generalist, creds emitted, work-repo registered
2. `aon connect alice` again → no duplicate add, just re-joins
3. `aon connect aon://TOKEN BITS` → unaffected
