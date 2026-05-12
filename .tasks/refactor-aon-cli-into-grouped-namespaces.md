---
column: Backlog
---

# Context

`aon` CLI has ~24 flat top-level commands. Refactor into intuitive namespaces. Hard rename, no compat aliases.

**Reviewers:**
- tim — review admin flow (`aon admin` commands: init, onboard, reinit, revoke, nats, tunnel)
- joana — review joiner flow (`aon connect TOKEN BITS` end-to-end)

**Tester:** rona

# Final Command Tree

```
aon admin
├── init                         # create aon.toml + dirs (one-time)
├── onboard NAME [KIND]          # add role + auth + reinit + emit creds + commit
├── reinit                       # re-mint auth + bootstrap NATS streams/KV + render prompts
├── revoke [ROLE|list|clear]     # manage revoked user JWTs
├── nats [up|down|logs|status|reload]
└── tunnel [up|down|status]

aon connect <token> <bits>       # token-based join (clone repo, place creds, handshake)
aon launch ROLE [WORK_REPO]
aon monitor [ROLE]
aon pub SUBJECT PAYLOAD
aon sub SUBJECT
aon req SUBJECT PAYLOAD
aon doctor
aon mcp-server [aon|board]
aon hook NAME [args]

# internal — callable by hooks, not shown in help
aon resolve-env [--strict]
```

# Removed Commands

| Old command | Reason |
|---|---|
| `add-role` | absorbed into `onboard` |
| `join` | replaced by `connect` |
| `join-link` | renamed `connect` |
| `connect` (waiting-room) | dropped — admin never online |
| `admit` | no waiting-room = no admit |
| `creds` | `onboard` emits, `reinit` re-emits |
| `auth render` | absorbed into `reinit` |
| `auth set-passwords` | was already no-op |
| `auth migrate` | nobody used it |
| `bootstrap` | absorbed into `reinit` |
| `prompts render` | absorbed into `reinit` |
| `prompts show` | not needed — read file directly |
| `apparmor` | Linux-only, unused |
| `set-nats-url` | was deprecated |
| `nats migrate-mount` | nobody used it |

# Implementation Steps

1. Add `cmd_admin()` dispatcher in `bin/aon` — routes to init/onboard/reinit/revoke/nats/tunnel
2. Add `cmd_reinit()` — calls auth render + bootstrap + prompts render
3. Rename `cmd_join_link` → `cmd_connect`, update case entry
4. Remove all dropped command case entries + function bodies
5. Demote `resolve-env` from help output (keep callable)
6. Update `cmd_help()` with grouped sections: ADMIN / CONNECT / RUNTIME
7. Update `cmd_onboard()` to call `cmd_reinit` internally
8. Delete `bin/aon-apparmor`
9. Update any agent-prompts referencing old command names

# Files
`bin/aon` (~2975 lines), `bin/aon-apparmor` (delete)
