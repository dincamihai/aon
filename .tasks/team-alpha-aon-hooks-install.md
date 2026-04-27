---
column: Backlog
created: 2026-04-27
order: 243
priority: medium
parent: team-alpha-meta-aon-cli
---

# Card 243 — `aon hooks install` (or fold into `aon init` / `aon launch`)

Today the operator runs `bash
~/Repos/ai-over-nats/scripts/hooks/install.sh` from inside the
team or work repo. Engine-relative path. Easy to skip.

## Goal

```bash
aon hooks install [<target-repo>]
```

Wraps `scripts/hooks/install.sh`. Targets the team repo by
default; `<target-repo>` optionally points at a work repo
(joiner case — same as the env-baked variant in `join.sh`).

Or — preferred — fold into `aon init` (team repo case) and
`aon launch` (work repo case) so it runs implicitly. Operator
never thinks about hook installation.

## Acceptance

- After `aon init`, the team repo has a `.claude/settings.json`
  with the hooks wired up (or a hooks-installed marker).
- `aon launch <role> <work-repo>` ensures the work repo's
  `.claude/settings.json` has env-baked hook commands (matches
  current `join.sh` jq pipeline).
- Re-running is idempotent.

## Why

Removes one more "do this engine-relative bash thing" from the
operator + joiner runbooks.
