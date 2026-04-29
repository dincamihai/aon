---
column: Done
priority: high
created: 2026-04-29
owner: rona
---

# PR #58 e2e results — set-nats-url --role fix + ACL drift detection (F2)

Branch: `joana/fix-f2-acl-drift` commit `94b0b50`

## Results (round 1)

| Case | Result | Notes |
|------|--------|-------|
| 1 `aon set-nats-url --role tim BITS` probes with tim.creds | PASS | probe landed on agents.tim.events; agents.rona.events empty |
| 2 single-role-per-team set-nats-url unchanged | PASS | no --role → uses AON_ROLE=rona → probes with rona.creds, handshake OK |
| 3 `aon auth render` reports drift after ACL string change | PASS | pre-existing drift on mid (manager) detected: expected=082b473c current=8432cb58 |
| 4 `--apply-acl-drift` re-issues affected users | PASS | mid re-issued; "ACL drift fixed for 1 user(s) — redistribute updated .creds files" |
| 5 no drift reported when ACLs match | PASS | second `aon auth render` after fix → "✓ no ACL drift" |
| 6 regression: auth render happy path unchanged | PASS | all 4 stages pass; 2b/4 ACL check integrated cleanly |

## Notable: caught real drift

`--apply-acl-drift` caught pre-existing mid user drift (manager ACL changed in PR).
Feature works in production — not just synthetic test.

## Fix verified

**set-nats-url:** `"${explicit_role:-$_first_role}"` → `explicit_role=tim` when `--role tim` passed.
Probe publishes to `agents.tim.events` using `tim.creds`.

**ACL drift:** `_aon_nsc_acl_sig()` computes expected ACL hash from source.
`_aon_nsc_jwt_acl_sig()` reads current ACL hash from NSC JWT.
Drift detected when hashes differ. `--apply-acl-drift` deletes + re-issues + re-emits creds.

## Verdict

**Ready to merge.** All 6 cases pass. Drift detection working in production.
