---
column: Backlog
---

# Review and triage 10 stale branches (feat/fix/docs/tim)
# Review and triage stale branches

Branches that predate the PR#62 CLI refactor. Each needs: code review, conflict check against current main, decision merge/rebase/delete.

## feat/ branches (real code, likely conflict)

- `feat/agent-prompt-git-workflow` — git workflow rules in agent prompts (may be superseded by role-brief additions)
- `feat/hmac-payload-signing` — HMAC envelope signing, tamper evidence + replay protection
- `feat/multi-skill-roster-schema-card` — roster schema extension for multi-skill roles
- `feat/skills-impl` — PR #28 open — `aon skills` (8 skills + install + auto-link in join)
- `feat/slim-token-tunnel-rotation-card` — slim token v2 + cloudflared bits + tunnel rotation
- `feat/streamline-onboard-card` — `aon onboard` + `aon join-link` streamline

## fix/ branch

- `fix/hooks-install-merge-order` — hooks install: rebuild paths per-machine, untrack settings.json

## docs/ branches

- `docs/readme-join-fixup` — PR #25 open — README clarify join cwd/work-repo/auth
- `docs/readme-vahid-trial` — unknown content
- `docs/sub-a-scoping-notes` — unknown content

## tim/ branches (unreported)

- `tim/aws-ec2-nats-via-ssm`
- `tim/fix-cmd-connect-onboard-friction`
- `tim/per-repo-hooks`

## Process

For each branch:
1. Check if code still applies to current main (may be obsolete post-refactor)
2. If superseded → delete
3. If still valid → rebase + open PR or merge
