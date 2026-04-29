---
column: Backlog
---

# aon launch: MCP not configured / role not synced
## Problem

`aon launch <role>` sets AON_ROLE env but doesn't configure MCP server for Claude Code. Result: `/mcp` shows no servers, and system doesn't know current role.

When AON_ROLE=sun is set, Claude should:
- Know it's running as "sun"
- Have MCP server properly wired (if configured)
- Use sun's credentials + permissions

Instead: MCP missing, role detection fails or defaults to stale value (joana).

## Root Cause

`aon launch` installs hooks (SessionStart, etc) but doesn't:
1. Create/update `.claude/settings.json` with MCP config
2. Sync AON_ROLE to a place Claude Code can read it on startup
3. Verify MCP server sees the new role before launching

## Related Issue

`aon launch sun` → "you are joana" suggests cached/stale MCP config or missing role sync mechanism.

## Solution

Option A: Include MCP config in `aon launch` hook installation
Option B: Have hooks set AON_ROLE in Claude Code's environment early (SessionStart)
Option C: Auto-detect AON_ROLE from env + pass to MCP at init time

Recommended: A + B (belt + suspenders)
