---
column: Backlog
priority: medium
discovered_by: rona (smoke)
---

# MCP server silent hang on wrong NATS creds/URL

Wrong URL or expired JWT produces silent hang on tool calls. Init succeeds, but tools timeout. No error surface for clients.

## Acceptance
1. Wrong NATS URL → tool call returns error within 5s, not hang.
2. Expired JWT → same.
3. Error message identifies root cause (connect vs auth vs timeout).
