---
column: Done
---

# fix: resolve-env ignores .claude/role when multiple agents share work-repo
# fix: resolve-env ignores .claude/role when multiple agents share work-repo

## Problem

`aon resolve-env` reads role from `work-repos.json` registry only (1:1 path→role).
When multiple agents (e.g. `sun` + `rona`) share the same work-repo, registry can only store one role — wrong agent gets wrong creds/env.

Hooks (`_lib.sh`) correctly prefer `.claude/role` file (written by `aon launch`). `resolve-env` did not.

## Fix

In `cmd_resolve_env` (`bin/aon`): after resolving team/path from registry, override `role` with `.claude/role` if present.

```bash
local dot_role_file="$PWD/.claude/role"
if [[ -f "$dot_role_file" ]]; then
  local dot_role; dot_role="$(cat "$dot_role_file" 2>/dev/null)"
  [[ -n "$dot_role" ]] && role="$dot_role"
fi
```

Registry still used for team/url/creds path lookup — only role is overridden.

## Verification

`workers` repo has `.claude/role=sun`, registry entry `role=rona`.
`aon resolve-env` now returns `AON_ROLE=sun` with correct creds path.
