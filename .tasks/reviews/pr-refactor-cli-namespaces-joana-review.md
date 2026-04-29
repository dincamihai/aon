---
branch: sun/refactor-cli-namespaces
reviewer: joana
focus: joiner flow (aon connect TOKEN BITS)
date: 2026-04-29
verdict: changes-needed
---

# Review — sun/refactor-cli-namespaces (joiner angle)

## Verdict: CHANGES-NEEDED (2 blockers, 2 non-blocking)

---

## BLOCKER 1 — Troubleshooting table: wrong command in `BucketNotFoundError` fix

`README.md` line ~200:

```
| `BucketNotFoundError` in MCP server | `AON_KV_BUCKET` not in env | `aon connect <team>` — writes `AON_KV_BUCKET` to team env file |
```

`aon connect <team>` is not a valid command. Should be `aon connect <token> <bits>`. Also `aon join <role> <work-repo>` in the row above is now stale (command renamed).

Fix:
```
| `BucketNotFoundError` in MCP server | `AON_KV_BUCKET` not in env | `aon connect <token> <bits>` — re-runs setup, derives KV bucket from aon.toml |
| `aon` refuses to run / wrong team detected | Not in a registered work-repo | `aon connect <token> <bits>` first, or set `AON_TEAM_DIR` |
```

---

## BLOCKER 2 — pynacl section now stale

`README.md` line ~57:

> **`pynacl` (needed by `aon connect`)** — auto-bootstrapped on first run...

`aon connect TOKEN BITS` (the renamed `join-link`) doesn't use pynacl — it decodes a base64 token with `base64 -d` and parses JSON with `jq`. The old waiting-room `cmd_connect` that used box encryption is removed in this branch. The pynacl section (auto-bootstrap docs, air-gapped fallback, doctor check) is all stale. Remove or move to the waiting-room admin docs if that flow still exists somewhere.

---

## Non-blocking 1 — `_cmd_join_local` mangled comment

`bin/aon` line ~1493:

```bash
# via 'aon creds'. Joiner side: must have been delivered by
# creds must be delivered via 'aon connect TOKEN BITS' — bail with a
# clear msg.
```

First line is a leftover sentence fragment from editing `cmd_join` → `_cmd_join_local`. Should be one clean sentence.

---

## Non-blocking 2 — Work-repo prompt not surfaced in quickstart

`cmd_connect` prompts `"Work-repo path [...]: "` when run outside a git repo (or when the cwd is the team repo itself). The quickstart shows `aon connect TOKEN BITS` as the second command without mentioning this prompt. A joiner running from `~/` or from the engine repo hits an unexpected interactive prompt after the "2 commands" setup.

Suggest: either auto-exit with a clear message (`aon_fail "run from inside your work-repo, or pass work-repo as env/arg"`) or add a note to the quickstart: "run from your work-repo directory, or enter the path when prompted."

---

## Overall joiner UX

Flow reads cleanly as 2 commands:
1. `gh repo clone ... && aon connect aon://<token> <bits>`
2. `cd <work-repo> && claude`

Rotation mode (re-run updates URL, no re-clone) is correct and documented. Token version gate (v1 warn / v2 fail / v3 proceed) is clear. The `aon connect TOKEN BITS` rename from `join-link` is the right move — much more discoverable.
