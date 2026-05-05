# cmd-gate — argv-level safety gate

`cmd-gate` is `aon`'s answer to the fact that agents launch with
`claude --dangerously-skip-permissions` ([bin/aon][launch]) — the
built-in permission prompts are off, so the **`PreToolUse` hook is
the only argv-level enforcement layer** between the agent and the
host shell.

The colima-VM AppArmor sandbox ([docs/sandbox.md][sb]) is the outer
ring (filesystem + syscall isolation). It cannot tell `aws s3 ls`
from `aws s3 rm` or `SELECT` from `DROP TABLE`. `cmd-gate` is the
inner ring that reads argv intent.

## Layers

```
Bash tool invocation
  └─► .claude/settings.json PreToolUse → scripts/hooks/pre-tool-use.sh
        └─► scripts/security/cmd-gate.sh
              1. tool != Bash (or path tool with credential path)
                  → allow / deny credential paths
              2. enabled=0  → allow
              3. deny.local.regex   → deny  (user override)
              4. deny.regex         → deny  (hard floor)
              5. AON_GATE_BYPASS=1  → allow (skips 6–8)
              6. cache hit          → return cached verdict
              7. allow.local.regex  → allow (user override)
              8. allow.regex        → allow (fast path)
              9. ollama classifier  → allow | deny | ask
              10. ask               → operator-ask over NATS,
                                      timeout → fallback (default ask)
```

## Files

```
scripts/security/
  _lib.sh                  shared env + helpers
  cmd-gate.sh              entry point (called by pre-tool-use.sh)
  classifier-ollama.sh     argv → JSON via /api/generate
  cache.sh                 file-based verdict cache
  audit.sh                 publish to NATS evt.security.gate.<role>
  operator-ask.sh          request/await reply over NATS
  policy/
    allow.regex            fast-path safe argv
    deny.regex             hard-floor destructive argv
scripts/hooks/
  pre-tool-use.sh          Claude Code hook entry, dispatches to cmd-gate
bin/aon-security-watch     curses TUI for live operator approval
```

## Operator UX

```
aon security watch              # primary: live curses TUI, y/n approve
aon security pending            # JSON list of waiting requests
aon security approve <id> [r]   # one-shot approve
aon security deny    <id> [r]   # one-shot deny
aon security bypass on|off      # escape hatch (deny.regex still bites)
aon security cache  status|clear
aon doctor                      # checks ollama + model + policy files
```

## Personal overrides

Outside-the-repo files, hot-reloaded on every gate call:

```
~/.aon/security/allow.local.regex   extra always-allow patterns
~/.aon/security/deny.local.regex    extra always-deny (wins over allow)
~/.aon/security/bypass              empty file → marker for bypass
```

Same model as the AppArmor personal-override pattern in
[docs/sandbox.md][sb]. Mirror these into your dotfiles repo if you
want them tracked.

## Config (env, today)

| Var | Default | Notes |
|---|---|---|
| `AON_GATE_ENABLED` | `1` | `0` to disable everything |
| `AON_GATE_BYPASS` | `0` | `1` skips classifier + allow layers; deny.regex still bites |
| `AON_GATE_MODEL` | `nemotron-3-nano:4b` | ollama model tag |
| `AON_GATE_OLLAMA_URL` | `http://127.0.0.1:11434` | classifier endpoint |
| `AON_GATE_TIMEOUT_MS` | `4000` | classifier deadline |
| `AON_GATE_CACHE_TTL` | `3600` | seconds |
| `AON_GATE_ASK_TIMEOUT` | `60` | seconds to wait for operator reply |
| `AON_GATE_FALLBACK` | `ask` | `ask | deny | allow` on classifier/operator failure |

`aon launch` warms the model with `keep_alive=24h` so the first
ambiguous Bash call doesn't pay the ~6 s ollama cold-start.

## NATS subjects

| Subject | Direction | Payload |
|---|---|---|
| `evt.security.gate.<role>` | gate → operators (audit) | verdict envelope |
| `evt.coord-in.gate-request.<id>` | gate → operator | argv + reason |
| `evt.coord-out.gate-reply.<id>` | operator → gate | `{decision,operator,reason}` |

The TUI reuses these — no extra IPC.

## Background

PoC scored **42/42** across destructive verbs, hidden CLI flags
(`aws s3api delete-objects --cli-input-json file://`), base64
obfuscation, python+SQL via psycopg2, character-code SQL building
(`chr(68)+chr(82)+chr(79)+chr(80)`). Plan and reasoning live in
[`.tasks/aon-cmd-gate-ollama-classifier.md`](../../.tasks/aon-cmd-gate-ollama-classifier.md).

[launch]: ../../bin/aon
[sb]: ../../docs/sandbox.md
