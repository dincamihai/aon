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

---

## Round 2 retest — `sun/fix-admit-dispatch` commit `8aaed93`

| Case | Result | Notes |
|------|--------|-------|
| `aon admit` (no args) | PASS | Usage shown with list/approve/reject |
| `aon admit list workers` | PASS | Lists pending requests, count correct |
| `aon admit approve` (no args) | PASS | `✗ usage: aon admit approve <team> <box_id> <role>` |
| `aon admit reject` (no args) | PASS | `✗ usage: aon admit reject <team> <box_id> [reason]` |
| `aon admit reject workers rejectbox999 "reason"` | PASS | `✓ rejected box_id=rejectbox999` |
| `aon admit approve workers realbox456 tim` | FAIL | `_cmd_connect_python: command not found` → `✗ encryption failed` |

## New Bug: `_cmd_connect_python` not defined

`cmd_admit_approve` calls `_cmd_connect_python` at line 2579 to encrypt creds
for the joiner, but the function is not defined anywhere in `bin/aon`.
Approve flow always fails at the encryption step regardless of valid input.

`aon admit reject` works end-to-end. `aon admit list` works. `aon admit approve` broken.

**Verdict:** Partial fix. Dispatcher wired (regression fixed), reject works, but approve
broken due to missing `_cmd_connect_python` function.
