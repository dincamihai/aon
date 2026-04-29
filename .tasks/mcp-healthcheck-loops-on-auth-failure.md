---
column: Done
priority: medium
created: 2026-04-29
source: rona exploratory (Bug 6) on 4d5911b..62dc26d
---

# MCP healthcheck loops raw tracebacks on bad creds; never exits cleanly

`mcp-server/src/aon_mcp/__main__.py` — `_healthcheck()`.

## Repro

```sh
echo "fake creds data" > /tmp/fake.creds
AON_CREDS=/tmp/fake.creds timeout 20 aon mcp-server aon 2>&1
echo "exit: $?"
```

Prints ~10+ repeated raw tracebacks over 20s:

```
nats: 'Authorization Violation'
nats: 'Authorization Violation'
...
```

The friendly error defined in `_healthcheck()` ("NATS auth rejected — check … is valid for role '…'") never reaches stderr. Process is killed by external `timeout` (exit 124), not a clean exit.

## Fix

In `_healthcheck()`:

1. Catch the auth-rejection exception explicitly (auth errors are non-transient).
2. Emit the friendly message once.
3. `sys.exit(1)`.

Do **not** retry on auth failure. Retry only on transient connectivity (connection refused, network timeout) with bounded backoff.

## Acceptance

1. With bad creds: mcp-server prints one friendly line, exits with code 1 within ~2s.
2. With unreachable NATS: bounded retries (e.g. 3) with backoff, then exits with code 1.
3. With valid creds: starts normally.
4. Logs no raw traceback on the auth-fail path.

## Related

- `mcp-healthcheck-missing-await-on-nc-close.md` (F1/D5) — fix together, both touch the same exception paths.
