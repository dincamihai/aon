---
column: Backlog
priority: medium
created: 2026-04-29
parent: team-alpha-meta-aon-cli.md (sun/refactor-cli-namespaces review)
source: tim review (B3)
---

# `cmd_onboard` error message still uses old top-level command name

Found during review of `sun/refactor-cli-namespaces`.

## Issue

`bin/aon:1619` (in `cmd_onboard`):

```bash
aon_err "usage: aon onboard NAME [KIND] [DOMAIN]"
```

`aon onboard` is no longer a valid top-level command after the CLI namespace refactor.
The correct command is `aon admin onboard NAME [KIND] [DOMAIN]`.

An operator who misuses the command gets an error that tells them to run a command that
no longer exists, leading to a second confusing error.

## Fix

```bash
aon_err "usage: aon admin onboard NAME [KIND] [DOMAIN]"
```

One-line change.

## Acceptance

1. `aon admin onboard` (no args) prints `usage: aon admin onboard NAME [KIND] [DOMAIN]`.
2. `bash -n bin/aon` passes.
