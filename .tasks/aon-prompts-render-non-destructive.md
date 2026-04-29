---
column: In Progress
priority: medium
created: 2026-04-29
source: mid + sun design conversation 2026-04-29
decision: 2026-04-29 — C + A hybrid (mid + sun)
owner: joana
---

# `aon prompts render` should not overwrite — separate common from custom

## Problem

`aon prompts render` (also fired by `aon onboard` step 2/7 + `aon auth render`) renders `agent-prompts/<role>.md` from `templates/agent-prompts/<kind>.md.tmpl` every run. Per-role customization made directly in the rendered file is silently destroyed on the next render.

This breaks the natural workflow:

- Bootstrapping a new team → render is exactly right (scaffold from templates, fast).
- Day-to-day → roles diverge: tim picks up specific tooling, rona accumulates test-run heuristics, sun's `sun.md` carries digest/dispatch logic. None of that should be in templates because it isn't team-portable.
- Today's only safe path is "edit the template, then re-render", which forces every per-role tweak into a global-by-default location. Sun has been hand-editing rendered files and losing them.

## Goal

Make role prompts editable in place after initial scaffold. Common content (substrate model, ACLs, hard rules, long-payload rule) should still be a single source of truth — but injected at runtime, not stomped into the file.

## Options (pick one + flesh out)

### A — `render` becomes one-shot

`aon prompts render` refuses to overwrite an existing file unless `--force`. Default = scaffold-on-first-run. Sub-option: render section-by-section between `<!-- AON-BEGIN: common -->` / `<!-- AON-END: common -->` markers; preserve everything outside markers. Lowest churn — everyone keeps editing rendered files, just not getting clobbered.

### B — Serve common via MCP `get_role_brief()`

`agent-prompts/<role>.md` becomes purely role-specific. Common substrate / ACL / rules content moves into the `aon` MCP server's `get_role_brief()` response. Claude calls it on first turn (already documented in the new repo-level `CLAUDE.md`). Pro: zero stale-template risk; per-role files stay small. Con: one more layer of indirection; needs MCP available (joiner via `aon connect` already gets it).

### C — Hybrid (recommended)

- Render once, scaffold per-role. After that, never overwrite (option A).
- Move strictly substrate-level content (subject taxonomy, hard rules, long-payload rule, current-focus block) into `get_role_brief()` so it can evolve without touching rendered files at all (option B).
- Per-role files retain only role-specific guidance — easy to read, easy to edit, no merge conflicts with template updates.

Card C as the working assumption; revisit if MCP availability becomes a blocker.

### Decision (2026-04-29) — C + simple `{{include}}` directive

Locked: **MCP `get_role_brief()` serves substrate** (the canonical content) **+ simple `{{include path}}` directive in per-role files** for any portable snippet that needs to live in the file (e.g. operator-intents table when MCP isn't available, or per-team focus blocks).

- No Jinja or full templating engine. Bash-resolvable include only.
- `aon prompts render` becomes one-shot scaffold-only: refuse to overwrite without `--force`.
- Substrate content moves out of `templates/agent-prompts/_common.md.tmpl` into a single source consumed by both `get_role_brief()` MCP tool AND (as a fallback) the include resolver.

Sun manually edits both surfaces:
- Substrate evolution → edit MCP source / canonical content file → all roles see on next session.
- Per-role tweaks → edit `agent-prompts/<role>.md` → safe, never stomped by render.

## Acceptance

1. **One-shot render:** `aon prompts render` (and the call from `aon onboard`) refuses to overwrite an existing `agent-prompts/<role>.md`. Prints "exists, skipping (use --force to overwrite)". `--force` keeps the current destructive behavior.
2. **Canonical substrate source:** A single file (e.g. `templates/role-brief.md`) holds the substrate/ACL/hard-rules/long-payload-rule content. Editing this file is how the team evolves common rules.
3. **MCP serves it:** `get_role_brief()` MCP tool returns the rendered brief (canonical source + per-role specifics resolved). Claude calls on first turn (already wired in CLAUDE.md).
4. **Include directive:** Per-role files may use `<!-- AON-INCLUDE: <path> -->` (or `{{include path}}`). A bash-only resolver expands them when something reads the file directly (e.g. `aon prompt show <role>`). Path is relative to `$AON_ENGINE_DIR/templates/`.
5. **Templates slim down:** `_common.md.tmpl` shrinks to the bootstrap scaffold (operator-intents table, NATS env basics). Everything portable moves to `templates/role-brief.md`.
6. **Existing role files keep working:** First post-upgrade run of `aon onboard` is a no-op on populated `agent-prompts/`.
7. **Joiner flow:** `aon connect` still produces a usable `agent-prompts/` for a fresh joiner (one-shot scaffold runs because nothing exists yet).

## Out of scope

- Migrating ALL prompt content. Some pieces (example DM payloads, role-specific cycle loops) stay rendered.
- A general templating engine. The marker-based partial render is enough.

## Affected files (sketch)

- `bin/aon` — `cmd_prompts_render` (around line 401-425): add overwrite refusal + marker preservation, OR strip non-role-specific sections.
- `templates/agent-prompts/_common.md.tmpl` — split into "stays in template" + "moves to MCP brief".
- `mcp-server/src/aon_mcp/server.py` (or wherever `get_role_brief` lives) — extend response with common substrate content.
- All existing rendered `agent-prompts/*.md` — no migration needed; first run after upgrade is a no-op.

## Why now

Hit twice in two days:
- Sun's PR-review-policy edit to `agent-prompts/_common.md` (2026-04-29 morning) — wiped by a later `aon onboard` re-render.
- Long-payload rule needed to be added — only safe path was a template edit + PR (added friction; per-role tweaks should not need cross-team review).

The pattern is set up to fight day-to-day evolution.
