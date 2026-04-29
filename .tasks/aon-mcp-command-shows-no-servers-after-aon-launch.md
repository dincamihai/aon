---
column: Done
---

# aon: /mcp command shows no servers after `aon launch`
## Problem

After `aon launch <role>`, typing `/mcp` shows no available MCP servers even though the aon MCP server should be configured.

Expected: aon MCP server appears in `/mcp` list, ready to use (`aon monitor`, `aon pub`, etc)
Actual: Empty list, user has to manually configure or doesn't realize MCP is available

## Context

- CLAUDE.md instructs agents to call `get_role_brief()` (MCP function) on first turn
- But MCP server never appears as available
- Agent can't discover/use MCP without explicit /mcp configuration

## Root Cause Hypothesis

- MCP server configured globally in ~/.claude/settings.json but not in project
- Or: MCP server name doesn't match what Claude Code looks for
- Or: .claude/settings.json in project overrides without including MCP

## Fix

`aon launch` should:
1. Ensure aon MCP server is in `.claude/settings.json` mcpServers
2. Or document that agents should manually connect MCP on first turn
3. Or wire it up in SessionStart hook

Alternatively: Improve /mcp discoverability or auto-load aon MCP when AON_ROLE is set.
