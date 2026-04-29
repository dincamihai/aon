---
column: Backlog
priority: critical
created: 2026-04-29
parent: waiting-room-natscore-race-joiner-req-lost.md
owner: joana
blocked-by:
  - waiting-room-cmd-connect-kv-rewrite.md
  - waiting-room-cmd-admit-list-and-approve-reject.md
---

# Subtask 5/5: code review — waiting-room KV migration

Joana review of tim's three subtasks (1, 2, 3) before merge.

## Focus areas

### 1. ACL correctness (subtask 1)

- Anon JWT pub/sub list matches the actual JS API subjects `nats kv put / get / watch / del / ls` hit. Wrong subject = `Permissions Violation` at runtime.
- Anon CANNOT reach `$KV.workers-state.>`. Confirm via `nsc describe user` + a probe pub.
- No regression in deny-default semantics (allow-only ACLs since trivials PR).

### 2. Race / persistence semantics (subtask 2 + 3)

- `nats kv watch --history 1` on the reply key: does it see a value written *before* the watch starts? (KV watch should yield the existing value on first event; verify.)
- TTL: 30m bucket TTL means a long-running joiner that publishes early could see its request key disappear before approval. 30m is the agreed appetite; flag if shorter is needed in practice.
- Concurrent joiners: each `box_id` is uuid-hex → no collision risk on request/reply keys.
- Cleanup: who deletes `request.<box_id>` if joiner dies between put + watch? Bucket TTL covers it eventually, but the orphan lives 30m. Acceptable.

### 3. Reply payload integrity

- Encrypted ciphertext path is unchanged from current code (only the transport changes). Confirm no plaintext leaks via KV history.
- `kv put` + `kv del` ordering on approve: if admin is interrupted between put-reply and del-request, joiner already got the reply (correct). Re-running `admit list` would show the request again, but `admits.log` dedup catches it.

### 4. Error paths

- Joiner timeout (300s) — clear message, non-zero exit.
- Admin approve on missing request — clear error.
- Bucket missing — actionable error pointing at `aon auth render` (or `aon nats reload` or the bootstrap step).

### 5. Doc + dead code

- `reply_subj` variable removed.
- MODEL.md or README updated to reflect the new subject layout (or at least PR description spells it out).
- No reference to `team.<team>.waiting-room` left anywhere except a deprecation note.

## Process

1. Pull the fix branch.
2. Read each diff hunk against this card + the parent card + the implementation plan at `~/.claude/plans/let-s-discuss-the-critical-abstract-pizza.md`.
3. Post inline comments on the PR.
4. **Do NOT click GitHub Approve** (per workers PR review policy).
5. DM `agents.sun.inbox`:

```json
{"type":"review-done","from":"joana","card":"waiting-room-kv-code-review","branch":"<branch>","verdict":"ready-for-final|changes-needed|blocked","summary":"...","concerns":[...]}
```

6. Final approval = sun + mid co-review.
