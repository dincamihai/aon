---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 48
priority: high
parent: nsc-jwt-migration
---

**Shipped** in e1a84a1 — new `_aon_nsc_push_team_jwt` helper folded
into `cmd_revoke` + `cmd_revoke clear` + `cmd_auth_render`. Soft-
fails when server unreachable. Misleading info-lines dropped.
`cmd_nats_reload` help text corrected.



# `aon revoke` doesn't actually propagate — fold `nsc push` into the flow

S5 review surfaced a real gap. `cmd_revoke` writes the new account
JWT to disk via `_aon_nsc_publish_team_jwt` and prints "force
immediate reload: aon nats reload". Two problems with that path:

1. **Disk-only writes don't propagate at runtime.** The Phase D
   smoke (commit 3f6505f, S5c+d) found this the hard way:

   > The resolver dir is server-write-only mid-run; updates must
   > go via `nsc push` (`$SYS.REQ.CLAIMS.UPDATE`).
   >
   > The earlier Phase D draft (rewrite-on-disk + SIGHUP) silently
   > accepted post-revoke pubs because the in-memory account JWT
   > was never updated.

2. **`aon nats reload` sends SIGHUP** (commit e9ba15c, S5b). Per
   #1 above, SIGHUP did NOT actually pick up the new JWT in Phase
   D's earlier draft. So the info-line directive
   "force immediate reload: aon nats reload" is misleading.

Net effect on the production rotation flow:

- Operator runs `aon revoke vahid`.
- `_aon_nsc_publish_team_jwt` writes new JWT to disk.
- Server keeps the old in-memory JWT until the next 2m scan
  interval (default).
- During that window, vahid can still publish — even though the
  operator believes vahid is revoked.
- `aon nats reload` per the info line may or may not help
  (Phase D evidence says no for SIGHUP).

`nsc push` (the path Phase D actually uses to prove revoke works)
is the correct propagation primitive. It needs to be folded into
`cmd_revoke` so revocations are atomic and immediate.

## Fix

Make `cmd_revoke` (and `cmd_revoke clear`) call `nsc push` after
republishing the JWT to disk. Update the info lines accordingly.

### Code

`bin/aon` `cmd_revoke`:

```bash
# After _aon_nsc_publish_team_jwt:
nsc push -a "$team" -u "$AON_NATS_URL" >/dev/null \
  || aon_warn "nsc push failed — running server keeps old JWT until next resolver scan (default 2m)"
aon_ok "revoked $role; team JWT published + pushed to running server"
```

Drop the "force immediate reload: aon nats reload" info line —
`nsc push` already triggered immediate update.

If `aon revoke` is run while NATS is down, `nsc push` will fail;
that's fine — the disk JWT is still updated and server picks up
on next start. Warn but don't fail.

### Optional helper

Extract a `_aon_nsc_push_team_jwt <team>` helper in `_aon-lib.sh`
so `cmd_auth_render` can also call it after first-time JWT
generation. Avoids the same gap on initial roster expansion.

## Documentation cleanup

1. **`scripts/nsc-smoke/run-smoke.sh:463-465`**: Phase D header
   comment still says "+ SIGHUP". Fix to "+ nsc push" to match
   actual code.

2. **`docs/runbooks/nsc-rotate-user.md`**: verify the runbook
   doesn't tell operators to use `aon nats reload` for immediate
   revoke effect. If it does, redirect to the new `aon revoke`
   (which does the push internally).

3. **`bin/aon` `cmd_nats_reload` help text**: the claim "the disk
   resolver re-reads its dir + JWTs immediately" may be wrong.
   Either verify SIGHUP-resolver-dir-reload behavior on
   current nats-server, or downgrade the help text to
   "may speed up resolver scan, no guarantee" + point to
   `nsc push` as the reliable path.

## Acceptance

- `aon revoke <role>` propagates the revocation to the running
  server immediately (≤1s after the command returns), not in 2m.
  Validated by extending Phase D in `run-smoke.sh` to invoke
  `aon revoke` directly (currently uses raw `nsc revocations
  add-user` + `nsc push`).
- `aon revoke clear <role>` similarly immediate.
- Phase D header comment matches the implementation.
- Rotation runbook's directives align with the new immediate
  behavior.
- `cmd_nats_reload` help text accurate about what SIGHUP does
  for the dir resolver (or alternative reliable path documented).
- If NATS is down when `aon revoke` runs: warn, don't fail; disk
  JWT still updated; server picks up at next start.

## Out of scope

- Replacing the resolver-dir model with the cache resolver
  (`resolver: URL` mode) — separate scaling decision.
- `nsc push` for non-revocation account-level edits (covered by
  the same plumbing once this fix lands).
- Native (non-docker) nats-server reload path (separate card if
  needed).

## References

- Commit 3f6505f (S5c+d) — Phase D smoke proving `nsc push`
  works.
- Commit e9ba15c (S5b) — `aon nats reload` SIGHUP advertised.
- `bin/_aon-lib.sh:402-411` — `_aon_nsc_publish_team_jwt`
  (disk-only write).
- `bin/aon` `cmd_revoke` (~ line 967) — current revoke flow.
