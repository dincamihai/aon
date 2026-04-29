---
column: Backlog
priority: low
created: 2026-04-29
source: tim review (D6) on 4d5911b..62dc26d
---

# mcp-server: `BucketNotFound` CamelCase check never matches lowercased string

Commit `6e1b6d5` (`fix(mcp): add startup healthcheck for connectivity + KV bucket`).

`mcp-server/src/aon_mcp/__main__.py:~134` — `err_str = str(e).lower()` lowercases the error string, then `if "BucketNotFound" in err_str` is checked. The CamelCase literal can never match a lowercased string. Falls through to the generic `KV error:` path instead of the user-friendly bucket-not-found guidance.

## Fix

```python
# current (broken)
if "bucket not found" in err_str.lower() or "BucketNotFound" in err_str:

# fix — err_str is already lowercased
if "bucket not found" in err_str or "bucketnotfound" in err_str:
```

## Acceptance

1. Triggering a missing-bucket error in MCP startup prints the user-friendly hint, not the generic message.
2. Add a unit / regression test for the error path.
