---
column: Backlog
created: 2026-04-27
order: 244
priority: medium
parent: team-alpha-meta-aon-cli
---

# Card 244 — `aon publish` — GitHub repo wrapper

POC trial steps included:

```bash
gh repo create dincamihai/team-poc-aon --private --source . --remote origin --push
gh repo edit dincamihai/team-poc-aon --add-collaborator <vahid-gh-username>
```

Two manual `gh` calls. Wrappable.

## Goal

```bash
aon publish [--owner OWNER] [--collaborator GH_USER...] [--public]
```

- Default owner = `gh api user --jq .login`.
- Default visibility = `--private`.
- One `--collaborator` flag per joiner; multiple allowed.
- Refuses if `aon.toml` has `name = "<placeholder>"` (avoid
  publishing default-named repos).
- After push, prints the invite-out-of-band block (role, password
  ref, NATS URL) so operator can copy-paste into 1Password.

## Acceptance

- Empty team repo + `aon init` + edits + `aon publish
  --collaborator vahid-gh` creates a private repo + invites
  vahid + prints the share block.
- Re-running noops on existing repo + adds new collaborators.

## Why

Trial showed two tools (gh repo create, gh repo edit) plus
remembering correct flags. One CLI removes the friction.
