---
column: Done
priority: medium
created: 2026-04-29
source: joana audit (F1) on 4d5911b..62dc26d
---

# mcp-server: missing `await` on `nc.close()` in `_healthcheck()`

Commit `6e1b6d5` (`fix(mcp): add startup healthcheck for connectivity + KV bucket`).

`mcp-server/src/aon_mcp/__main__.py:128,142` — KV-error and publish-error paths call `nc.close()` without `await`. `nats-py` `close()` is a coroutine; unawaited = connection never closed.

Low real-world impact (startup-only, process exits on failure) but wrong and triggers asyncio warnings.

## Fix

`await nc.close()` on both paths.

## Acceptance

1. Both error paths in `_healthcheck()` await the close.
2. No `RuntimeWarning: coroutine 'Client.close' was never awaited` during a failing healthcheck.
