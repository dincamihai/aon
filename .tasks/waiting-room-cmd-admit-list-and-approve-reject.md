---
column: Backlog
priority: critical
created: 2026-04-29
parent: waiting-room-natscore-race-joiner-req-lost.md
owner: tim
blocked-by: waiting-room-kv-bootstrap-and-anon-acl.md
---

# Subtask 3/5: rewrite `cmd_admit_list` + add `approve` / `reject` subcommands

Admin side. Replaces drain via `nats sub --raw` with KV listing; implements the missing `approve` / `reject` subcommands.

## Scope

`bin/aon:2596-2679` — `cmd_admit` dispatcher + `cmd_admit_list` + new `cmd_admit_approve` + `cmd_admit_reject`.

### `cmd_admit_list` rewrite

Current (broken):
```bash
raw="$(nats --server "$url" --creds "$creds" sub "$waiting_room_subj" --count 100 --wait 3s --raw 2>/dev/null)" || true
# --raw drops reply-to envelope (F3); NATS Core drops messages if admin wasn't pre-subscribed (Bug 4)
```

New:
```bash
local bucket="${team}-waiting-room"
local keys
keys="$(nats --server "$url" --creds "$creds" kv ls "$bucket" 2>/dev/null | grep '^request\.' || true)"
if [[ -z "$keys" ]]; then
  aon_ok "no pending requests"
  return 0
fi

# Iterate, fetch payload, dedup against admits.log, render table.
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  local box_id="${key#request.}"
  if grep -q "^${box_id}\b" "$ADMITS_LOG" 2>/dev/null; then
    continue   # already handled
  fi
  local payload
  payload="$(nats --server "$url" --creds "$creds" kv get "$bucket" "$key" --raw 2>/dev/null || true)"
  [[ -z "$payload" ]] && continue
  # Existing render-table logic, fed by $payload
  ...
done <<<"$keys"
```

### `cmd_admit_approve` (new)

```bash
cmd_admit_approve() {
  local team="${1:-}" box_id="${2:-}" role="${3:-}"
  [[ -n "$team" && -n "$box_id" && -n "$role" ]] || {
    aon_err "usage: aon admit approve <team> <box_id> <role>"
    return 2
  }

  local bucket="${team}-waiting-room"
  local req_key="request.${box_id}"
  local reply_key="reply.${box_id}"

  # 1. Pull request to read joiner_pubkey for crypto.
  local req_payload joiner_pub
  req_payload="$(nats kv get "$bucket" "$req_key" --raw 2>/dev/null)"
  [[ -n "$req_payload" ]] || aon_fail "no pending request for box_id=$box_id"
  joiner_pub="$(jq -r .joiner_pubkey <<<"$req_payload")"

  # 2. Build creds bundle (existing path: roster check + creds emit + share-block token).
  local share_block; share_block="$(_aon_build_share_block "$team" "$role")" \
    || aon_fail "could not build share block for role=$role"

  # 3. Encrypt with joiner_pub.
  local ciphertext
  ciphertext="$("$_py" "$AON_ENGINE_DIR/scripts/aon-crypto/box.py" encrypt --to "$joiner_pub" <<<"$share_block")"

  # 4. Publish reply via KV.
  jq -c -n --arg role "$role" --arg ct "$ciphertext" '{ok:true,role:$role,ciphertext:$ct}' \
    | nats kv put "$bucket" "$reply_key"

  # 5. Cleanup request key.
  nats kv del "$bucket" "$req_key" >/dev/null 2>&1 || true

  # 6. Append to admits.log (existing dedup mechanism).
  printf '%s\t%s\t%s\n' "$box_id" "$role" "$(date -u +%FT%TZ)" >> "$ADMITS_LOG"

  aon_ok "approved box_id=$box_id role=$role"
}
```

### `cmd_admit_reject` (new)

```bash
cmd_admit_reject() {
  local team="${1:-}" box_id="${2:-}" reason="${3:-rejected by admin}"
  [[ -n "$team" && -n "$box_id" ]] || {
    aon_err "usage: aon admit reject <team> <box_id> [reason]"
    return 2
  }
  local bucket="${team}-waiting-room"
  jq -c -n --arg reason "$reason" '{ok:false,reason:$reason}' \
    | nats kv put "$bucket" "reply.${box_id}"
  nats kv del "$bucket" "request.${box_id}" >/dev/null 2>&1 || true
  aon_ok "rejected box_id=$box_id reason=\"$reason\""
}
```

### Dispatcher (`cmd_admit`)

```bash
case "$sub" in
  list)    cmd_admit_list "$@" ;;
  approve) cmd_admit_approve "$@" ;;
  reject)  cmd_admit_reject "$@" ;;
  *)       aon_err "usage: aon admit {list|approve|reject} ..." ; return 2 ;;
esac
```

### Reuse (do NOT rewrite)

- `_aon_build_share_block` (or whichever existing helper builds the joiner's onboarding bundle — find via grep around `cmd_join_link` / `cmd_creds`).
- `scripts/aon-crypto/box.py encrypt --to <pub>` for the ciphertext.
- `$ADMITS_LOG` path resolution.

## Acceptance

1. `aon admit list <team>` shows all pending request keys regardless of order with joiner.
2. `aon admit approve <team> <box_id> <role>` writes reply key, deletes request, appends to admits.log.
3. Joiner side (subtask 2) receives reply within timeout, decrypts, writes team env, exits 0.
4. `aon admit reject <team> <box_id> "reason"` writes negative reply, joiner exits non-zero with the reason printed.
5. Re-running `aon admit list` after approve does not show the same box_id (dedup via admits.log + kv del).
6. Smoke test (subtask 4) covers approve + reject paths.
7. `bash -n bin/aon` passes; aon-tests green.

## Out of scope

- Bug 5 (URL validation), Bug 6 (mcp healthcheck loop) — separate cards.
- Auditing the existing `_aon_build_share_block` helper for security regressions — assume it's already correct; we're just changing the transport.

## Review policy

No GitHub Approve. `review-done` DM to sun.
