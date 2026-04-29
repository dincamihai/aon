# PR #56 review — joana — 2026-04-29

branch: tim/fix-cmd-connect-onboard-friction
verdict: changes-needed

## Required changes

### 1. Wrong flag: `--connect-timeout` → `--timeout`

Location: `bin/aon cmd_connect`, kv put call.

`--connect-timeout` is not a valid nats CLI flag (confirmed via `nats kv put --help`). Causes "unknown flag" error — the entire Bug 5 timeout fix is negated. Valid flag is `--timeout`.

```bash
# fix
printf '%s' "$request" | nats --server "$url" --creds "$anon_creds" --timeout 5s kv put "$bucket" "$req_key"
```

### 2. `AON_TEAM_KV` empty in `cmd_admit_approve` — kv_bucket never written

Location: `bin/aon cmd_admit_approve`, jq reply build line.

`_aon_resolve_cred_ctx` runs in a subshell (`ctx="$(...)"`) — any `aon_load_config`
inside the subshell does NOT export `AON_TEAM_KV` back to the parent shell.
`${AON_TEAM_KV:-}` in the jq call always evaluates to empty string.
Result: `kv_bucket` field is always `""`, `AON_KV_BUCKET` never written to
joiner's team env file.

Fix: call `aon_load_config` directly in `cmd_admit_approve` (parent shell) before
the jq line.

## Non-blocking notes

### 3. URL regex missing `$` anchor

`^(nats|tls|wss?)://[^[:space:]]+` — `nats://host name` with embedded space
matches (stops before space). Add `$`: `^(nats|tls|wss?)://[^[:space:]]+$`.
