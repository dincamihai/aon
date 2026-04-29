---
column: Backlog
priority: high
created: 2026-04-29
parent: team-alpha-meta-aon-cli.md (sun/refactor-cli-namespaces review)
source: tim review (B4) + mid discussion
---

# `aon admin reinit` has no per-role option — compromised creds cannot be rotated cleanly

Found during review of `sun/refactor-cli-namespaces`.

## Issue

After a creds compromise the operator flow is:
1. `aon admin revoke <role>` — JWT revoked at NATS level ✓
2. `nsc delete user --account <team> <role>` — delete old JWT (manual, no aon wrapper)
3. Re-issue: `nsc add user ...` + emit `.creds` (manual)

`aon admin reinit` (full 3-step) does NOT help: `_aon_nsc_ensure_user` skips existing users
(`if nsc describe user ... return 0`), so it won't re-issue the role whose JWT was deleted.

`aon creds ROLE` was removed from the top-level dispatch in the refactor. `cmd_admin` has no
`creds` subcommand. There is no aon command that combines delete + re-issue + emit for a
single role.

**Severity:** High. Compromised-creds rotation requires raw `nsc` commands — not documented,
error-prone, breaks the "no raw nsc" operator contract.

## Fix

Extend `aon admin reinit` to accept an optional `[ROLE]` argument:

```bash
aon admin reinit          # full 3-step: auth render + bootstrap + prompts render (unchanged)
aon admin reinit <role>   # single-role: nsc delete user (force) + re-issue + emit .creds only
```

Single-role path in `cmd_reinit`:
```bash
if [[ -n "${role:-}" ]]; then
  # Force re-issue: delete existing JWT so _aon_nsc_ensure_user re-creates it.
  nsc delete user --account "$team" "$role" >/dev/null 2>&1 || true
  _aon_nsc_ensure_user "$team" "$kv" "$role" "$kind" "$domain" "$learning" \
    || aon_fail "re-issue failed for $role"
  _aon_nsc_emit_creds "$team" "$role" "$(_aon_team_creds_dir "$team")/$role.creds"
  aon_ok "re-issued creds for $role — distribute new .creds out-of-band"
  return 0
fi
# ... existing 3-step path ...
```

`kind`/`domain`/`learning` must be read from `aon.toml` for the named role (same as drift-check
loop in `cmd_auth_render`).

## Acceptance

1. After `aon admin revoke tim` + `nsc delete user` (simulated compromise), `aon admin reinit tim`
   re-issues JWT + emits `tim.creds`.
2. `aon admin reinit` (no arg) unchanged — all 3 steps run for all roles.
3. `aon admin reinit <unknown-role>` fails with a clear error (role not in roster).
4. New `.creds` file is chmod 600.
