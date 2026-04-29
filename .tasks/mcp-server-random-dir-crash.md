---
column: Backlog
priority: high
discovered_by: rona (smoke)
---

# MCP server crashes with traceback when run outside project dir

Full Python traceback with BucketNotFoundError when `aon mcp-server aon` run from random directory. Should print clean "not in a project" message.

## Acceptance
1. Running `aon mcp-server aon` from `/tmp` prints one-line error, not traceback.
2. Exit code non-zero.
3. Message includes suggested fix (cd to team repo or set AON_ROLE).
