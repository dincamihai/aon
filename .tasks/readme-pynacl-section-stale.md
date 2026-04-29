---
column: Backlog
priority: medium
created: 2026-04-29
parent: team-alpha-meta-aon-cli.md
source: joana review — sun/refactor-cli-namespaces
---

# README pynacl section is stale after waiting-room connect removal

## Problem

`README.md` contains a `pynacl` prerequisite section that says:

> **`pynacl` (needed by `aon connect`)** — auto-bootstrapped on first run...

The old waiting-room `cmd_connect` used box encryption (pynacl). In the CLI namespace refactor, the waiting-room `cmd_connect` was removed; `aon connect TOKEN BITS` is the renamed `cmd_join_link`, which only uses `base64 -d` + `jq`. No pynacl needed.

The section includes:
- Auto-bootstrap description (`.venv` creation)
- Air-gapped fallback pip install instructions
- `aon doctor` venv health check reference

All stale after this branch.

## Fix

Remove the pynacl prerequisite section entirely. If the waiting-room admin flow (box encryption) still exists somewhere, move the pynacl docs there instead.

Also update `aon doctor` to not check for pynacl venv (or at minimum not fail on its absence) since `aon connect` no longer needs it.

## Acceptance

1. README has no pynacl section.
2. `aon doctor` passes on a clean install without pynacl.
3. If waiting-room crypto remains somewhere, pynacl docs appear in that flow's section only.
