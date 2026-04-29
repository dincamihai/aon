---
branch: sun/refactor-cli-namespaces
reviewers: tim (admin angle) + joana (joiner angle)
date: 2026-04-29
verdict: changes-needed
---

# Combined Review — sun/refactor-cli-namespaces

## BLOCKERS

### B1 (joana) — README troubleshooting table: stale/wrong commands

`README.md` ~line 200:
- `aon connect <team>` is not a valid command — should be `aon connect <token> <bits>`
- `aon join <role> <work-repo>` is stale (command renamed)

Fix:
```
| `BucketNotFoundError` in MCP server | `AON_KV_BUCKET` not in env | `aon connect <token> <bits>` — re-runs setup, derives KV bucket from aon.toml |
| `aon` refuses to run / wrong team detected | Not in a registered work-repo | `aon connect <token> <bits>` first, or set `AON_TEAM_DIR` |
```

### B2 (joana) — pynacl README section now stale

`README.md` ~line 57: "pynacl (needed by `aon connect`)" — `aon connect TOKEN BITS` (renamed from `join-link`) uses `base64 -d` + `jq`, not pynacl. Old waiting-room `cmd_connect` using box encryption is removed. The entire pynacl auto-bootstrap section, air-gapped fallback, and doctor check are stale. Remove or move to waiting-room admin docs if that flow still exists.

### B3 (tim) — `cmd_onboard` error message uses old command name

`bin/aon:1619`:
```bash
aon_err "usage: aon onboard NAME [KIND] [DOMAIN]"
```
Should be `aon admin onboard NAME [KIND] [DOMAIN]`.

### B4 (tim) — No `aon admin creds ROLE` for surgical creds re-emit

`aon creds ROLE` removed from top-level dispatch. `cmd_admin` has no `creds` subcommand. If a single role's `.creds` file is deleted/corrupted, operator must run full `aon admin reinit` (auth render + bootstrap + prompts render) to re-emit it. The old `aon creds ROLE` was surgical and fast. Suggest: add `aon admin creds ROLE [DEST]` routing to `cmd_creds`.

---

## NON-BLOCKING

### NB1 (joana) — `_cmd_join_local` mangled comment

`bin/aon` ~line 1493 — leftover sentence fragment from refactor:
```bash
# via 'aon creds'. Joiner side: must have been delivered by
# creds must be delivered via 'aon connect TOKEN BITS' — bail with a
```
First line is incomplete. Clean up to a single sentence.

### NB2 (joana) — Work-repo prompt not in quickstart

`cmd_connect` prompts `"Work-repo path [...]: "` when run outside a git repo. Quickstart shows `aon connect TOKEN BITS` as the second command with no mention of this interactive prompt. Joiner running from `~/` hits an unexpected prompt. Options: auto-fail with clear message, or add quickstart note ("run from your work-repo").

### NB3 (tim, observation) — `aon auth render` / `aon bootstrap` / `aon prompts render` removed from top-level

`admin reinit` bundles all three atomically — good default. But if an operator needs to re-run just one step (e.g. prompts render after template change), they must run the full 3-step reinit. Intentional tradeoff? If so, document it.

---

## What works well

- `cmd_onboard` NATS 3-mode handling (external / managed-running / managed-down) is correct
- `admin revoke` + `admin tunnel` present and correctly routed
- `init → onboard → launch` happy path reduced from 6 manual steps to 2 — clean
- `aon connect TOKEN BITS` rename from `join-link` is much more discoverable
- Rotation mode (re-run updates URL, no re-clone) is correct and documented
- Token version gate (v1 warn / v2 fail / v3 proceed) is clear
