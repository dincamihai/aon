---
column: Backlog
priority: critical
created: 2026-04-29
parent: waiting-room-natscore-race-joiner-req-lost.md
owner: tim
blocked-by: waiting-room-kv-bootstrap-and-anon-acl.md
---

# Subtask 2/5: rewrite `cmd_connect` to use KV (joiner side)

Replaces the broken `nats req` flow with KV put + watch.

## Scope

`bin/aon:2725-2810` — `cmd_connect`.

### Current (broken)

```bash
local reply_subj="team.${team}.waiting-room.${box_id}.reply"   # dead code, unused
...
reply="$(printf '%s' "$request" | nats --server "$url" --creds "$anon_creds" req "$waiting_room_subj" --wait 300000)"
# --wait is not a real flag → falls back to 5s timeout (D3); reply never arrives because of NATS Core race (Bug 4)
```

### New (target)

```bash
local bucket="${team}-waiting-room"
local req_key="request.${box_id}"
local reply_key="reply.${box_id}"

# 1. Embed reply target in request payload (was F3-style fix; trivial here since reply
#    location is fully defined by box_id).
request="$(jq -c -n ... '{v:$v,box_id:$box_id,hostname:$hostname,user:$user,joiner_pubkey:$joiner_pubkey,fingerprint:$fingerprint,ts:$ts}')"

# 2. Publish request via KV (persists; admin can list later).
printf '%s' "$request" | nats --server "$url" --creds "$anon_creds" kv put "$bucket" "$req_key" \
  || aon_fail "could not publish join request to $bucket/$req_key"
aon_info "join request published — waiting for admin approval (timeout 300s)"

# 3. Watch reply key. KV watch returns immediately if key already has a value (no race).
reply="$(nats --server "$url" --creds "$anon_creds" kv watch "$bucket" "$reply_key" --timeout 300s --history 1 2>/dev/null | head -n 1)"
[[ -n "$reply" ]] || aon_fail "timeout waiting for admin reply (300s)"

# 4. Cleanup own request key (defensive; admin's approve/reject also deletes).
nats --server "$url" --creds "$anon_creds" kv del "$bucket" "$req_key" >/dev/null 2>&1 || true
```

### Drop dead code

- `reply_subj` variable (`bin/aon:2760`) — supersedes F4.
- `--wait 300000` — was always wrong (D3).
- All `nats req` wiring for waiting-room.

### Reply parsing

Unchanged — admin's reply payload format `{ok, role, ciphertext}` stays. Only the transport changes.

## Acceptance

1. `aon connect <url> <team>` against a healthy admin completes successfully end-to-end (ties to subtask 3 + 4).
2. `aon connect` runs **before** admin starts `admit list` — request still visible to admin when they list.
3. `aon connect` runs **after** admin started `admit list` — same.
4. Multiple concurrent joiners — each gets the right reply.
5. No `Permissions Violation` from anon ACL during the flow (subtask 1 must be merged first).
6. Joiner exits within ~10s on a malformed URL or unreachable server (mitigates Bug 5; not a hard requirement here but easy win since `nats kv` connect timeout is a real flag).
7. `bash -n bin/aon` passes; existing aon-tests still green.

## Out of scope

- Approve / reject subcommands (subtask 3).
- Bug 5 deeper URL validation — only the easy timeout win comes for free here.
- Bug 6 healthcheck loop — separate file.

## Review policy

No GitHub Approve. `review-done` DM to sun.
