---
branch: sun/refactor-cli-namespaces
reviewers: joana (joiner angle), tim (admin angle)
date: 2026-04-29
verdict: changes-needed
---

# Combined review — sun/refactor-cli-namespaces

## Blockers

### B1 (tim) — `cmd_onboard` error message has wrong command
`bin/aon:1619`: error message still prints `aon onboard` instead of `aon admin onboard`.

### B2 (tim) — `aon admin creds ROLE` missing
Surgical per-role creds re-emit removed from top-level, not re-exposed under `admin`. Old `aon creds ROLE` let operator re-emit a single stale creds file (e.g. after `--apply-acl-drift`). Now `aon admin reinit` is the only option — re-runs auth+bootstrap+prompts for the whole team. Suggest adding `admin creds ROLE [DEST]`.

### B3 (joana) — README troubleshooting table: stale commands
- `aon connect <team>` (not a valid command) — should be `aon connect <token> <bits>`
- `aon join <role> <work-repo>` — renamed to `aon connect TOKEN BITS`

### B4 (joana) — README pynacl section stale
`pynacl` section says "needed by `aon connect`" — but token-based `connect` only uses `base64 -d` + `jq`. The waiting-room `cmd_connect` that used box encryption was removed. Remove pynacl bootstrap docs (or move if waiting-room flow still lives elsewhere).

## Non-blocking

### NB1 (joana) — `_cmd_join_local` mangled comment (~line 1493)
```bash
# via 'aon creds'. Joiner side: must have been delivered by
# creds must be delivered via 'aon connect TOKEN BITS' — bail with a
```
Leftover sentence fragment from edit. One clean line needed.

### NB2 (joana) — Work-repo prompt not shown in quickstart
`aon connect TOKEN BITS` prompts for work-repo path if run outside a git dir. README §2 shows 2 commands without mentioning the prompt. Add note: "run from your work-repo, or enter the path when prompted."

### OBS (tim) — Top-level `auth render`/`bootstrap`/`prompts render` removed
These were previously runnable standalone (useful for debugging partial state). Now only reachable via `admin reinit`. Intentional? If yes, worth noting in a migration comment somewhere.

## Summary

4 blockers total. Core flow (2-command joiner setup) reads cleanly — `connect TOKEN BITS` is the right command name. Admin namespace is clean. Fixes are targeted; no structural rethink needed.
