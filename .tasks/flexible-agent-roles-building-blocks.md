---
column: Backlog
---

# Flexible agent roles — building blocks
## Context

Current role model has 3 hardcoded `kind` values (manager / generalist / specialist). Kind drives two things: (1) NATS ACL pattern, (2) prompt template selection. Everything else lives in the prompt file — one-shot scaffolded, then hand-edited.

`ari` in workers already proves the pattern: `kind=manager` in aon.toml, prompt manually rewritten as "architect." The system's mechanics are decoupled from role identity. **The prompt IS the role.**

Goal: make this a first-class feature. Scaffold any org role correctly without modelling the whole org chart in code.

---

## Core Insight

Split two concerns currently conflated in `kind`:

| Concern | Mechanical? | Current | Proposed |
|---|---|---|---|
| Bus permissions | Yes — NATS enforces | `kind` → hardcoded ACL | Keep `kind` as ACL archetype |
| Role identity + behavior | No — evolves via prompt | `kind` → template selection | `role` field → template, falls back to kind |

---

## Building Blocks

### B1: `role` field — separates identity from ACL archetype

```toml
[[roles]]
name   = "ari"
kind   = "manager"      # ACL archetype — mechanical
role   = "architect"    # identity — selects template
domain = "fullstack"
```

Template resolution: `architect.md.tmpl` → `manager.md.tmpl` fallback.

Teams grow a library of `role` templates (architect, tech-lead, qa-lead, devops, data-scientist, support) without changing ACL semantics.

### B2: Expanded template variables

- `@ROLE_KIND@` = the `role` field value (e.g. "architect")
- `@DESCRIPTION@` = optional one-liner from aon.toml
- `@PEERS@` = comma-separated roster names (auto-derived)

### B3: `skills` list — replaces single `domain` for multi-domain roles

```toml
skills = ["frontend", "backend", "testing"]
```

- First skill = primary (backward compat with `domain`)
- Specialist: `board.tasks.{skill[0]}.pending`; additional skills in learning track
- Generalist: skills used in prompt prose only (ACL unchanged)
- Backward compat: `domain` present + no `skills` → treat as `skills = [domain]`

### B4: New kind archetypes (longer-term, skip for now)

- `lead` = manager + contributor ACL merged (coordinates AND ships)
- `observer` = subscribe-only (stakeholders, reviewers)

3-kind model covers 80%+ of roles via `role` template field. Add when a real team hits the wall.

### B5: `role-brief.md` + AON-INCLUDE (already exists — no change)

The live-updating layer. One-shot prompt scaffold + evolving role-brief = the refinement loop.

---

## What Does NOT Change

- `kind` stays as ACL axis
- Templates remain one-shot scaffold (hand-edit after first render)
- aon.toml stays as static roster

---

## Rollout Order

1. **B1 + B2** — `role` field + expanded template vars. Low risk, big flexibility gain. `role` defaults to `kind` if absent.
2. **B3** — `skills` list. Needs _aon-lib.sh TOML array parsing + auth template changes.
3. **B4** — New kind archetypes. Only if needed.

---

## Critical Files

- `bin/_aon-lib.sh` — TOML parser (skills array), `_aon_nsc_ensure_user` (ACL per kind)
- `bin/aon` — `cmd_prompts_render` (template resolution, new vars), `cmd_auth_render`
- `templates/aon.toml.example` — schema docs
- `templates/agent-prompts/*.md.tmpl` — use new variables
- `templates/auth/specialist.tmpl` — multi-domain subscriptions
