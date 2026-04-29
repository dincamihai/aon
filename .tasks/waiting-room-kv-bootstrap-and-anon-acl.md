---
column: In Progress
priority: critical
created: 2026-04-29
parent: waiting-room-natscore-race-joiner-req-lost.md
owner: tim
blocks:
  - waiting-room-cmd-connect-kv-rewrite.md
  - waiting-room-cmd-admit-list-and-approve-reject.md
---

# Subtask 1/5: KV bucket + anon ACL for waiting-room

Foundation work. Lands first; subtasks 2 + 3 build on top.

## Scope

Two changes:

### 1. `scripts/bootstrap.sh:71` — ensure per-team waiting-room bucket

Add after the existing `ensure_kv "$AON_KV_BUCKET" 5 0`:

```bash
ensure_kv "${AON_TEAM}-waiting-room" 1 30m
```

- 1 history (we don't need value history; revisions are throwaway).
- 30m TTL — abandoned requests / replies expire automatically.

`AON_TEAM` is already in scope at this point in bootstrap.sh.

### 2. `bin/_aon-lib.sh:438-444` — replace anon ACL

Current:

```bash
anon)
  nsc add user --account "$team" "$name" \
    --allow-pub "team.${team}.waiting-room" \
    --allow-sub "team.${team}.waiting-room.*.reply,_INBOX.>" \
    --allow-pub-response >/dev/null
  ;;
```

(`--deny-pub ">"` + `--deny-sub ">"` already removed in `sun/fix-trivials-2026-04-29`.)

Replace with KV-scoped allow list. The exact JetStream API subjects `nats kv put / get / watch / del / ls` use under the hood, scoped to the bucket's underlying stream `KV_${team}-waiting-room`:

```bash
anon)
  local _wr_kv="\$KV.${team}-waiting-room"
  local _wr_str="KV_${team}-waiting-room"
  nsc add user --account "$team" "$name" \
    --allow-pub "${_wr_kv}.request.>,${_wr_kv}.reply.>" \
    --allow-sub "${_wr_kv}.reply.>,_INBOX.>" \
    --allow-pub "\$JS.API.STREAM.MSG.GET.${_wr_str},\$JS.API.STREAM.MSG.DELETE.${_wr_str},\$JS.API.STREAM.PURGE.${_wr_str},\$JS.API.CONSUMER.CREATE.${_wr_str}.>,\$JS.API.CONSUMER.MSG.NEXT.${_wr_str}.>,\$JS.API.CONSUMER.DELETE.${_wr_str}.>" \
    --allow-pub-response >/dev/null
  ;;
```

Verify the exact JS API subject set against `nats-py` / `nats kv` source if any subject is missing — symptom would be a `Permissions Violation` from `nats kv put` or `nats kv watch`.

The team subject `team.<team>.waiting-room` is gone. No other code paths use it (verified via grep at planning time).

## Acceptance

1. Fresh team init: `nats kv info ${team}-waiting-room` reports the bucket exists with TTL 30m and history 1.
2. `nsc describe user --account workers --name anon` shows the new KV-scoped subject set, no `team.<team>.waiting-room` pub.
3. Anon can run `nats kv put ${team}-waiting-room request.test '{"x":1}'` and `nats kv get ${team}-waiting-room request.test` without `Permissions Violation`.
4. Anon CANNOT pub to `$KV.workers-state.>` (regression check on blast radius).
5. Existing tests in `scripts/nsc-smoke/` and `scripts/aon-tests/` still pass.

## Notes

- Do NOT widen anon ACL beyond the new bucket. The whole point of per-team scoping is keeping anon away from `workers-state`.
- Existing `--deny-pub ">"` / `--deny-sub ">"` lines were already removed in trivials PR — don't re-add.
- After implementation, `aon auth render && aon creds anon` re-issues anon JWT. Restart NATS container so server picks up new account JWT.

## Out of scope

- Restructuring manager / generalist ACLs to also restrict KV scope (separate work).
- Documenting the new subject layout in MODEL.md (do as part of subtask 3 PR description).

## Review policy

Per workers PR-review policy: do NOT click GitHub Approve. Post review-done DM on `agents.sun.inbox` with verdict + concerns. Final = sun + mid co-review.
