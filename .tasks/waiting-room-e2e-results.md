---
column: Done
priority: high
created: 2026-04-30
owner: rona
---

# e2e results — waiting-room flow + anon ACL fix

Branch: `main` commit `bd7bbc2`

## Results

| Case | Result | Notes |
|------|--------|-------|
| 1. anon pub to `$KV.workers-waiting-room.request.*` | PASS | Published 64 bytes, no ACL violation |
| 2. anon sub to `$KV.workers-waiting-room.reply.*` | PASS | Subscription accepted (no reply, expected — no operator listening) |
| 3. `aon admit list` | FAIL | `✗ unknown command: admit` — not in CLI |
| 4. `aon admit approve` | FAIL | same — not wired |
| 5. `aon admit reject` | FAIL | same — not wired |

## Bugs Found

### BUG: `admit` commands not in CLI dispatcher — regression from PR #62

`cmd_admit_list`, `cmd_admit_approve`, `cmd_admit_reject` exist in `bin/aon`
(lines 2463, 2536, 2579) but have no dispatch entry in the CLI router.
`aon admit list/approve/reject` all return `✗ unknown command: admit`.
Introduced by PR #62 CLI namespace refactor — `admit` was not migrated.

### INFRA ISSUE: anon.creds still has MSG.DELETE — fix not deployed

Code fix (removed `$JS.API.STREAM.MSG.DELETE.KV_workers-waiting-room` from
`_aon_nsc_ensure_user` anon ACL) is correct, but creds cannot be re-issued:

```
Error: unable to resolve any of the following signing keys in the keystore:
  ACZDE7G4BJRPERTUZFSJSAIR2UVG25GRL6J7NHW7LIELAMQJVO4Z3WVG
```

NSC signing key for `workers` account missing from keystore. `nsc add user`
fails silently (stdout redirected to `/dev/null`, stderr lost). Existing
`anon.creds` JWT still contains `STREAM.MSG.DELETE` in pub allow list.

**Mitigating factor**: NATS server returned `"message delete not permitted"` when
anon attempted MSG.DELETE — blocked at stream config level (`denyDelete: true`
or equivalent) before ACL is checked. The ACL fix is correct defense-in-depth
but isn't the active blocker.

To fully deploy fix: restore signing key → run `aon admin reinit` → reload
NATS server (`aon admin nats reload` after `nsc push`).

## Verdict

**Not ready.** `admit` commands broken (CLI regression). Anon ACL code fix is
correct but not deployed due to missing NSC signing key — pre-existing infra issue.
`aon connect` anon flow works. Admit flow completely broken.
