---
column: Backlog
---

# Adopt A2A agent card spec — replace custom `agents/<role>.json` format

## Problem

`aon` declares agent capabilities in three custom, coupled places:

- `aon.toml` — operator-managed roster with `kind`, `domain`, role metadata
- `agents/<role>.json` — hand-crafted cards (custom schema)
- `agent-prompts/<role>.md` — rendered briefs derived from the above

Costs:
1. **Manual overhead** — every new agent requires operator edits across multiple files
2. **No external interoperability** — agents built with LangChain, Google ADK, CrewAI, etc. cannot join or be understood by `aon` agents
3. **Reinvented wheel** — the A2A protocol already defines a standardized format for exactly this purpose

## Goal

Replace the custom `agents/<role>.json` schema with a valid [A2A Agent Card](https://a2a-protocol.org/latest/specification/). Keep NATS as transport untouched.

## Implementation approach

Card generation and NATS publishing handled by a small Rust binary (`aon-card`) using the [a2a-rs SDK](https://github.com/a2aproject/a2a-rs) (Apache-2.0). `bin/aon` shells out to it — no runtime deps, single static binary.

`aon-mcp` (Python) reads cards as plain JSON from NATS KV — no A2A SDK needed on the read path.

**Card source of truth: agent prompt frontmatter.** Skills and capabilities are declared in YAML frontmatter in `agent-prompts/<role>.md`. `aon-card gen` parses this deterministically — no LLM needed, no hallucination risk. Card is regenerated on every `aon launch` so it always reflects the current prompt.

**`aon.toml` roles shrink to name-only.** `kind`, `domain`, and capability metadata move into prompt frontmatter. Operator only declares who gets NATS access:

```toml
[[roles]]
name = "tim"

[[roles]]
name = "sun"
```

This is scoped to A2A card adoption only. A full `aon` CLI rewrite in Rust is a separate decision.

## Changes required

**1. Agent card format** (`agents/<role>.json`)

Replace ad-hoc schema with valid A2A Agent Card:

```json
{
  "name": "tim",
  "description": "Backend specialist focused on API design and data pipelines",
  "url": "nats://team-alpha/agents/tim",
  "version": "1.0.0",
  "skills": [
    { "id": "api-design", "name": "API Design", "description": "Design and implement REST and gRPC APIs" },
    { "id": "data-pipelines", "name": "Data Pipelines", "description": "Build and maintain ETL and streaming pipelines" }
  ],
  "defaultInputModes": ["text"],
  "defaultOutputModes": ["text"]
}
```

**2. Agent prompt frontmatter** — add YAML frontmatter to `agent-prompts/<role>.md`:

```yaml
---
skills:
  - id: api-design
    name: API Design
    description: Design and implement REST and gRPC APIs
  - id: data-pipelines
    name: Data Pipelines
    description: Build and maintain ETL and streaming pipelines
---
```

**3. `aon-card` Rust binary** — new crate using `a2a-rs`. Two subcommands:
- `aon-card gen <role>` — parses prompt frontmatter, emits `agents/<role>.json` as valid A2A card
- `aon-card publish <role>` — reads card, publishes to NATS KV

**4. `aon launch`** — call `aon-card gen` then `aon-card publish` on every boot. Card always reflects current prompt.

**5. `aon admin onboard`** — remove custom card generation; `aon.toml` `[[roles]]` entries shrink to `name` only.

**6. Card publishing over NATS** — on agent boot, card published to:
```
agents.<role>.card  →  { <A2A Agent Card JSON> }
```
Agents and observers subscribe to `agents.*.card` for dynamic capability discovery — no central roster lookup.

**7. Peer discovery in agent prompts** — update `agent-prompts/_common.md` to call new MCP tool `get_peer_cards()` instead of static rendered brief. MCP server reads live from NATS KV (cards stored at boot) as plain JSON — no A2A SDK in Python.

## What does NOT change

- NATS as transport — no HTTP, no subject or auth changes
- `aon.toml` as operator source of truth for roster and NATS config
- Onboarding UX (`aon admin onboard`, `aon connect`, `aon launch`)
- Hook and MCP installation flow

## Effort estimate

| Task | Effort |
|---|---|
| Add frontmatter to all `agent-prompts/<role>.md` files | 1 day |
| `aon-card` Rust crate (`gen` + `publish` subcommands, `a2a-rs` dep) | 2–3 days |
| Wire `aon launch` → `aon-card gen` + `publish` | hours |
| Slim down `aon.toml` `[[roles]]` to name-only | hours |
| MCP `get_peer_cards()` tool | 1 day |
| Update `agent-prompts/_common.md` template | trivial |
| Docs + examples | 1 day |

**Total: ~1 week.**

## Open questions

1. Should `kind` (`manager`, `generalist`, `specialist`) move to prompt frontmatter as a custom A2A extension field, or be encoded as a skill?
2. Should external agents (non-Claude) self-register by publishing to `agents.<name>.card`, or remain operator-gated (operator adds name to `aon.toml` + provisions NATS creds)?
3. Is adopting the full A2A task lifecycle (not just cards) worth a follow-up proposal?

## Acceptance

- `aon-card gen <role>` reads prompt frontmatter, produces valid A2A card at `agents/<role>.json`
- Output passes `a2a-tck` validation
- `aon launch` calls `aon-card gen` + `aon-card publish` on every boot
- Card in NATS KV reflects current prompt after every restart
- `aon.toml` `[[roles]]` entries contain `name` only — no `kind`/`domain`
- `get_peer_cards()` MCP tool returns live cards from NATS KV
- External A2A-compatible agent card can be dropped into `agents/` and is understood by `aon` agents
- Existing `aon.toml` / onboarding UX unchanged
