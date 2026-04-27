---
column: Backlog
created: 2026-04-27
order: 1030
priority: medium
---

# Roster schema: support multiple primary skills per role

## Problem

`aon.toml` roster expresses each role with a **single** `domain` string
plus an optional `learning` second domain. Cap = 2 skills:

```toml
[[roles]]
name     = "vahid"
kind     = "generalist"
domain   = "python"      # primary, single
learning = "go"          # optional second (growth track)
```

Reality is wider:

- MCP `mcp-server/.../acl.py` already encodes **multi-skill** per role
  (vahid has `{python, go}`; raj has full polymath set). The substrate
  side can route to multiple skills per role. Roster side can't
  express it.
- Generalists like Vahid arrive saying "I do backend — Python, Go,
  some Terraform." With current schema:
  - `domain = "python", learning = "go"` — drops Terraform.
  - `domain = "fullstack"` — lumps everything into one bucket, loses
    granularity.
  - `domain = "backend-python-go"` (slug) — creates an isolated
    namespace nobody else publishes to; MCP skill routing can't match
    it.
- Adding a new generalist with 3+ primary skills today requires
  hand-editing `acl.py`, `cards.py`, `agents/<role>.json`, hooks, and
  `auth.conf` separately to keep them consistent. Single-source-of-truth
  property is broken.

## Scope

Extend the roster schema so a role can declare an array of primary
skills, with `learning` retained as the optional growth track.
Cascade through every layer that currently substitutes `@DOMAIN@`.

### Schema (proposed)

```toml
[[roles]]
name     = "vahid"
kind     = "generalist"
skills   = ["python", "go", "terraform"]   # NEW: array, ≥1
learning = "ui"                             # optional, single

# Backwards compat: single `domain = "python"` still parses, becomes
# skills = ["python"]. Renderer never emits the legacy field.
```

Recognised skill IDs (closed set, owned by MCP `acl.py`):
`python`, `go`, `ui`, `terraform`, `aws`, `fullstack`, plus `review`
and `manager` for non-generalist roles. New skill = explicit MCP
registration first, then roster reference.

### Cascade (every site that touches `domain`)

1. **`bin/_aon-lib.sh`** — TOML parser exposes `skills[]` array. Keep
   `domain` accessor as a shim returning `skills[0]` for legacy
   call-sites until they're migrated.
2. **`bin/aon prompts render`** — templates substitute `@SKILLS@` with
   comma-joined human list (`"python, go, terraform"`) and
   `@PRIMARY_SKILL@` with `skills[0]` for any single-domain prose.
3. **`bin/aon auth render`** — generates allow/deny ACLs for each
   skill in `skills[]`: `board.tasks.<skill>.>` per skill, not per
   role-domain. Wildcard accepted for full-coverage roles.
4. **`templates/agent-prompts/{generalist,specialist,manager}.md.tmpl`**
   — rewrite `@DOMAIN@` references to `@SKILLS@` (joined) /
   `@PRIMARY_SKILL@` (lead) consistently. Generalist template
   already says "comfortable across domains" — make it accurate.
5. **`templates/auth/*.tmpl`** — accept skill list, emit per-skill
   ACL blocks.
6. **`mcp-server/src/team_alpha_mcp/acl.py`** — single source of
   truth for skill→role mapping. Verify `roster.skills[]` is a
   subset of `acl.PRIMARY_SKILLS[role]`; mismatch = `aon doctor`
   warning.
7. **`mcp-server/src/team_alpha_mcp/a2a/cards.py`** — agent card
   `skills` field already supports multi (`raj.json` has 7).
   Re-generator reads roster `skills[]` straight through.
8. **`scripts/hooks/_lib.sh`** — board subscription patterns
   currently hardcoded by role. Generalize: read role's `skills[]`
   from `agents/<role>.json`, subscribe to
   `board.tasks.<skill>.pending` for each skill (preserve existing
   `*.pending` wildcard for known multi-skill roles).
9. **`agents/<role>.json` regenerator** — derive `skills[]` from
   roster, emit one card field entry per skill with `tier: primary`.
10. **`aon add-role`** — accept `--skills py,go,tf` form (or
    repeat-flag) in addition to legacy positional `DOMAIN`.

### Migration

- Migrate one role at a time. Vahid first (already multi-skill in
  `acl.py`).
- Existing roles with single `domain` keep working via the parser
  shim until their `[[roles]]` block is hand-converted.
- Delete the shim once all roster blocks use `skills[]`.

## Acceptance

- [ ] `aon.toml` accepts `skills = [...]` array on `[[roles]]`
      blocks; parser exposes the list; legacy `domain = "..."` still
      parses (back-compat shim), rendered output identical.
- [ ] `aon add-role --skills py,go,tf vahid generalist` (or
      equivalent) appends a multi-skill block.
- [ ] `aon prompts render` substitutes `@SKILLS@` (comma-joined) and
      `@PRIMARY_SKILL@` correctly. Generalist template reads natural
      with multi-skill roles.
- [ ] `aon auth render` emits per-skill ACL blocks for every skill
      in `skills[]`. Round-trip test: existing single-skill roles
      produce byte-identical `auth.conf` output before and after the
      refactor.
- [ ] `aon doctor` warns on roster ↔ `acl.py` skill mismatch (role
      lists a skill not in `PRIMARY_SKILLS`, or vice versa).
- [ ] `agents/<role>.json` regenerator emits one card-skill entry
      per roster skill with `tier: primary`.
- [ ] Hooks subscribe to `board.tasks.<skill>.pending` for every
      skill the role declares.
- [ ] Vahid lives entirely in roster as `skills = ["python", "go",
      "terraform"]` with no hand-edits to `acl.py` / `cards.py` /
      `agents/vahid.json` / `auth.conf` outside the renderers.
- [ ] Existing 6 roles' rendered artefacts (prompts, auth.conf,
      agent cards) byte-identical after migration.

## Non-goals

- Multiple `learning` domains. Stays single — growth track is
  intentionally narrow ("learning sprawl" is a real anti-pattern).
- Skill **levels** (junior/senior/expert per skill). Out of scope;
  card tiers in `agents/<role>.json` already carry that signal at
  the card level.
- New skill IDs. Adding `backend` etc. is a separate decision —
  this card lets a role declare *N existing* skills, doesn't expand
  the closed skill set.

## Triggered by

- 2026-04-27 trial-test onboarding of Vahid: `aon add-role vahid
  generalist backend` ran into the schema cap. Workaround for the
  trial = `domain = "python", learning = "go"` (both already in
  `acl.py`). This card removes the workaround for the next joiner.

## References

- [team-alpha-meta-aon-toml-schema.md](team-alpha-meta-aon-toml-schema.md)
  — current schema reference.
- `mcp-server/src/team_alpha_mcp/acl.py` — skill→role mapping
  source of truth.
- `mcp-server/src/team_alpha_mcp/a2a/cards.py` `ALL_ROLES` —
  closed role set.
- `agents/raj.json` — concrete example of multi-skill agent card
  (7 primary skills, 4 with mentor flag).
- `templates/agent-prompts/generalist.md.tmpl` — text already
  claims "comfortable across domains"; this card makes it accurate.
