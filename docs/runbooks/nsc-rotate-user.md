# NSC user rotation runbook

Operator playbook for rotating, revoking, and re-issuing NATS user
credentials under the JWT auth model
(`.tasks/nsc-jwt-migration.md`).

Audience: operators holding sysadmin .creds on the substrate's NSC
home. All commands assume the engine is on PATH (`bin/aon`).

---

## When to rotate

| Trigger                                       | Action                  |
|-----------------------------------------------|-------------------------|
| Joiner box compromised / lost                 | Revoke + re-issue       |
| Joiner leaves the team                        | Revoke (no re-issue)    |
| Periodic hygiene (no incident)                | Re-issue (no revoke)    |
| Subject ACL change for a role                 | `aon auth render` + re-issue |
| Operator signing key rotation                 | `nsc edit operator --sk generate` + push (separate runbook) |

Revocation invalidates every .creds emitted before the revocation
timestamp. Re-issue produces a fresh JWT signed with a higher iat,
which the revocation list does not match.

---

## Revoke a single user

Use when a specific role's creds are compromised, or the role is
leaving the team.

```bash
# In the operator's team-aon repo:
aon revoke <role>
```

What this does (mirrors Phase D in `scripts/nsc-smoke/run-smoke.sh`):

1. `nsc revocations add-user --account <team-account> --name <role>`
   adds the user's pubkey + an iat cutoff to the team's account JWT
   `nats.revocations` map.
2. `nsc push -a <team-account>` publishes the updated account JWT to
   the running server via `$SYS.REQ.CLAIMS.UPDATE`. The server applies
   the new claims in-memory immediately; the disk resolver dir is
   written by the server itself.
3. (Optional) `aon nats reload` sends SIGHUP to the running container.
   For revocations the push is sufficient — SIGHUP only matters for
   server-config changes (e.g., `nats-server.conf` edits).

Verify it took effect:

```bash
# From any host with the revoked .creds:
nats --server <url> --creds <path> pub agents.<role>.events probe
# Expected: "user authentication revoked" in stderr; non-zero exit.
```

---

## Clear a revocation

Use when the prior revoke was a precaution and the role should be
restored, OR when re-onboarding the same name to a fresh box.

```bash
aon revoke clear <role>
```

This calls `nsc revocations delete-user` + `nsc push`. **The original
.creds is still invalid** — its iat falls below the (now removed)
cutoff, but NATS-server may still cache the rejection until next
reconnect. Always pair with a re-issue.

---

## Re-issue creds for a role

Re-issue produces a fresh signed user JWT with a new iat, distributed
to the role's host:

```bash
aon creds <role>
# → ~/.aon/teams/<team>/creds/<role>.creds
```

Distribute the new file to the joiner via your existing secret
channel (waiting-room admit when that ships, or token v3 share-block
in the meantime).

---

## Sub B input — extract Ed25519 nkey seed from a .creds file

Sub B (the per-message identity-integrity layer) needs the role's
Ed25519 seed for offline signing. The seed lives in the .creds bundle
between the `BEGIN USER NKEY SEED` / `END USER NKEY SEED` markers.

One-liner:

```bash
awk '/BEGIN USER NKEY SEED/{flag=1;next} /END USER NKEY SEED/{flag=0} flag' \
    ~/.aon/teams/<team>/creds/<role>.creds
```

Output is a single `SU…` string (Ed25519 seed in NATS nkey format).
Hand it to Sub B's offline signer; never commit, never log.

To extract the *user public key* (matching the seed) for verification:

```bash
nsc describe user --account <team> --name <role> --field sub | tr -d '"'
```

---

## Acceptance check (run after rotation)

```bash
# Confirm the revocation list state on disk matches expectations.
nsc describe account --name <team> --field nats.revocations

# Confirm re-issued creds still work.
nats --server <url> --creds ~/.aon/teams/<team>/creds/<role>.creds rtt
```

Both should agree with the change you just made. If the rtt fails on
fresh creds, rerun `nsc push -a <team>` — the server may still hold a
stale view if your last push raced with a network blip.

---

## Out of scope

- Operator signing-key rotation — separate runbook (lands when Sub A
  needs offline signing-key custody).
- Account-level limit changes (JS quotas etc.) — same `nsc edit
  account` + `nsc push` plumbing as revocation, but covered in
  `nsc-cutover.md` for first-time setup.
- Cross-team credential moves — out of scope until multi-team
  scenarios land.
