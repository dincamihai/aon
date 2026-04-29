---
column: Backlog
priority: medium
created: 2026-04-29
source: rona note 2026-04-29 — surfaced after PR #48 + PR #51 ACL fixes
related:
  - aon-destructive-ops-audit.md (D6 — _aon_nsc_ensure_user silent skip)
---

# `aon auth render` should warn / fail when ACL definitions in source differ from existing user JWTs

## Problem

`_aon_nsc_ensure_user` (`bin/_aon-lib.sh:426`) is idempotent: if `nsc describe user --account <team> --name <role>` succeeds, it skips re-issuing the user. The intent is "don't churn JWTs on every render" — but the side-effect is that **ACL changes in the source code do NOT propagate to existing users**.

Rona hit this twice:
- PR #48 first cut shipped with anon `--allow-pub` missing `$JS.API.STREAM.INFO.KV_<bucket>` and admin `--allow-pub` missing `$KV.<bucket>.reply.>`. Operators had to manually `nsc delete user → aon auth render → aon creds <role>` to pick up the fix.
- PR #51 followup: same dance to pick up the ACL-3 / ACL-4 patches.

There's no signal in `aon auth render` output that the ACL string in `_aon_nsc_ensure_user` differs from the JWT actually on disk. Operators discover the drift at runtime via `Permissions Violation`.

## Goal

Make ACL drift visible at render time. Either:

1. **Warn:** print a yellow note for each existing user whose computed ACL list differs from its current JWT, with the exact `nsc delete user → render → creds` recipe.
2. **Auto-update:** delete + re-issue the affected users automatically (with a confirm prompt unless `--force`). Distribution of new creds remains the operator's job.
3. **Hybrid (recommended):** detect drift, list affected roles, and ask. Default = warn; `--apply-acl-drift` flag = re-issue.

## Implementation sketch

In `cmd_auth_render` (after the existing user-ensure loop):

```bash
for role in $(_aon_team_roles "$team"); do
  current_acl="$(nsc describe user --account "$team" --name "$role" --field nats.pub.allow,nats.sub.allow --raw 2>/dev/null)"
  expected_acl="$(_aon_nsc_compute_acl "$team" "$role" "$kind" "$domain")"  # new helper extracted from _aon_nsc_ensure_user
  if [[ "$current_acl" != "$expected_acl" ]]; then
    aon_warn "ACL drift on role=$role: source updated, JWT stale"
    aon_warn "  fix:  nsc delete user --account $team $role && aon auth render && aon creds $role"
    aon_warn "  then: redistribute $role.creds to whoever runs as $role"
    drift_count=$((drift_count+1))
  fi
done
```

Computing `expected_acl` requires factoring the per-kind ACL strings out of `_aon_nsc_ensure_user` so they can be inspected without actually creating a user. Worth doing anyway — currently the ACL definition is buried inside an `nsc add user` invocation, hard to test.

## Acceptance

1. After updating the ACL string in `_aon_nsc_ensure_user` (anon, manager, generalist, specialist, sysadmin), running `aon auth render` reports drift for every existing user whose ACL no longer matches.
2. Drift report names the role + the exact recipe to fix.
3. `--apply-acl-drift` flag automates the delete+re-issue.
4. Smoke test in `scripts/nsc-smoke/` covers: edit anon ACL → render → expect drift warning + actionable recipe.
5. Cross-link to `aon-destructive-ops-audit.md` D6 finding (silent-skip).

## Out of scope

- Auto-distributing re-issued creds (operator still owns that — touches multiple hosts).
- KV revocation push (existing `aon revoke` path covers).
- Splitting per-team operator JWTs (separate concern).

## Workaround until the feature lands — manual recreation after ACL change

When `_aon-lib.sh` ACL strings change (anon, manager, generalist, specialist, sysadmin), each existing team's existing users must be re-issued for the new ACLs to take effect. The substrate does **not** auto-detect this today.

### Steps (per affected role)

```sh
# 1. delete the stale user JWT from NSC.
nsc delete user --account <team> <role>

# 2. re-render auth (re-creates the user with the current ACL strings,
#    rewrites the team account JWT on disk).
aon auth render

# 3. emit fresh creds for the role.
aon creds <role>

# 4. distribute the new creds file to whoever runs as <role>:
#    cp ~/.aon/teams/<team>/creds/<role>.creds /path/to/host:/path/to/creds
#    chmod 600 on the destination.

# 5. on the running NATS container, push the new account JWT (or restart):
aon nats reload   # or: docker restart <team>-nats-1
```

### Triggered today by

- **PR #48 / #51** — anon ACL gained `$JS.API.STREAM.INFO.KV_<bucket>` + `$JS.API.DIRECT.GET.KV_<bucket>.>`; manager ACL gained `$KV.<bucket>-waiting-room.reply.>`. Operators upgrading from pre-PR-#48 must run the recipe above for `anon` + every manager role on every team.

### Sanity check

After re-issue, decode the user JWT and confirm the new subjects:

```sh
nsc describe user --account <team> --name <role> --field nats.pub.allow
nsc describe user --account <team> --name <role> --field nats.sub.allow
```

Or via creds file:

```sh
JWT=$(awk '/BEGIN NATS USER JWT/{f=1;next}/END NATS USER JWT/{f=0}f' \
  ~/.aon/teams/<team>/creds/<role>.creds | tr -d '\n')
PAYLOAD=${JWT#*.}; PAYLOAD=${PAYLOAD%.*}
PAD=$(( (4 - ${#PAYLOAD} % 4) % 4 ))
echo "${PAYLOAD}$(printf '=%.0s' $(seq 1 $PAD))" | base64 -d 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["nats"]["pub"]["allow"])'
```

Expect to see the new subjects in the list.

## Why medium

Not a bug per se — system works as designed when ACLs never change. But ACLs change every time we evolve the substrate (waiting-room rollout exposed this twice in one day). Without the warning, every ACL evolution is a silent footgun for operators of pre-existing teams.
