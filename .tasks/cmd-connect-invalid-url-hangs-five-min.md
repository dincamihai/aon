---
column: Done
priority: medium
created: 2026-04-29
source: rona exploratory (Bug 5) on 4d5911b..62dc26d
---

# `aon connect` with invalid NATS URL hangs full 5-minute timeout, no error

`bin/aon` — `cmd_connect`. Malformed URL example:

```sh
AON_NATS_URL='nats://[invalid-url:4222' aon connect workers
```

Hangs silently for 300s (full `nats req` timeout). No URL format validation before the attempt. User sees nothing for 5 minutes, assumes success or freeze.

## Fix

Either:
- Validate URL format with a regex / parse step before any `nats req` call. Reject obvious malformations with a clear error.
- Or pass `--connect-timeout 5s` to `nats req` so connectivity failure surfaces fast, then map the timeout error to a friendly "could not reach <url>" message.

Both ideally — strict format check + short connect timeout.

## Acceptance

1. `aon connect` with malformed URL exits within 6s with an actionable message naming the URL and suggesting `aon set-nats-url`.
2. `aon connect` against an unreachable but well-formed URL exits within ~10s, not 300s.
3. Valid URL + responsive admin still completes within the configured wait window.
