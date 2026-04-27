---
column: Backlog
created: 2026-04-27
order: 237
priority: medium
parent: team-alpha-team-portability
depends_on: team-alpha-meta-aon-cli, team-alpha-meta-agent-prompt-templates, team-alpha-meta-auth-conf-templates
---

# Card 237 — Meta: split engine code vs per-team data

Card 223 sketches the end-state shape. This card is the actual
move: refactor THIS repo into the **engine repo**, and document
how a team creates a **per-team repo** that consumes the engine.

## Engine repo (this one, post-split)

```
ai-over-nats/                            ← engine
  bin/aon                                ← CLI (Card 233)
  bin/_aon-lib.sh
  templates/aon.toml.example             ← Card 236
  templates/agent-prompts/{_common,manager,generalist,specialist}.md.tmpl   ← Card 234
  templates/auth/{sysadmin,manager,generalist,specialist,auth.conf}.tmpl    ← Card 235
  scripts/{bootstrap,onboard,join,worktree-claim,worktree-cleanup,ensure-clone}.sh
  scripts/sandbox/                       ← Cards 224 + 230 (already shipped)
  scripts/host/                          ← Card 229 (already shipped)
  scripts/hooks/                         ← reusable hooks
  mcp-server/                            ← team-alpha-mcp Python pkg
  schemas/                               ← event + card JSON schema
  docs/                                  ← engine docs (concepts, sandbox, aon CLI)
  README.md                              ← engine entrypoint
  pyproject.toml                         ← installable: pipx install aon
  examples/team-alpha/                   ← reference per-team repo, used as smoke
```

## Per-team repo (operator's repo, e.g. team-alpha-aon)

```
team-alpha-aon/
  aon.toml                               ← roster, paths, NATS URLs
  agents/<role>.json                     ← agent cards (rendered or hand-edited)
  agent-prompts/<role>.md                ← rendered from templates
  nats/auth.conf                         ← gitignored, generated
  nats/auth.conf.example                 ← rendered, committed
  .tasks/                                ← team's task cards
  docs/                                  ← team-specific docs (runbook, decisions)
  README.md                              ← team's home page
  .claude/                               ← claude config for this team
```

The per-team repo carries a single dependency: a clone of
ai-over-nats on disk (or pipx-installed `aon`). All team customisation
lives here.

## Migration steps for THIS repo

1. Move team-alpha-specific bits into `examples/team-alpha/`:
   - `.tasks/` → `examples/team-alpha/.tasks/`
   - `agents/<role>.json` → `examples/team-alpha/agents/`
   - `scripts/agent-prompts/<role>.md` → `examples/team-alpha/agent-prompts/`
   - `nats/auth.conf{,.example}` → `examples/team-alpha/nats/`
   - `docs/onboarding-per-role.md`, `team-session-runbook.md`,
     `team-bootstrap-prompt.md` → `examples/team-alpha/docs/`
   - `MODEL.md` → `examples/team-alpha/MODEL.md`
2. Promote shared scripts + hooks + mcp-server + sandbox to engine top-level.
3. New top-level `README.md` is engine-facing (replaces the current
   agent-onboarding one — Card 233 retargets `aon init`).
4. Add `aon.toml` to `examples/team-alpha/` as the canonical reference.

## Acceptance

- `examples/team-alpha/` is a fully working per-team repo: `cd` in,
  `aon init` is a no-op (already configured), `aon doctor` passes,
  `claude` launches correctly as any role.
- The engine repo's top-level no longer contains team-alpha role names
  in non-template code.
- A second example (`examples/example-team/`) starts a 3-role
  hello-world team with `aon init`.

## Risk + scope

Big card. Touch a lot of files. Recommend executing **after** Cards
233-236 land — they reduce churn (less hand-editing) during the move.
Plan for a single rebase-heavy PR.
