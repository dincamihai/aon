---
column: Backlog
priority: medium
created: 2026-04-29
parent: team-alpha-meta-aon-cli.md
source: joana review — sun/refactor-cli-namespaces
---

# README troubleshooting table has stale command names

## Problem

`README.md` troubleshooting table (post-rename branch) contains two stale entries:

1. `aon connect <team>` — not a valid command; was never valid. Should be `aon connect <token> <bits>`.
2. `aon join <role> <work-repo>` — renamed to `aon connect TOKEN BITS` in this branch.

Joiners hitting `BucketNotFoundError` or a "not in registry" error will follow wrong fix instructions.

## Fix

```markdown
| `BucketNotFoundError` in MCP server | `AON_KV_BUCKET` not in env | `aon connect <token> <bits>` re-runs setup and derives KV bucket from aon.toml |
| `aon` refuses to run / wrong team detected | Not in a registered work-repo | `aon connect <token> <bits>` first, or set `AON_TEAM_DIR` |
```

## Acceptance

1. Troubleshooting table has no `aon join` or `aon connect <team>` entries.
2. All fix commands in the table are valid and match current CLI surface.
