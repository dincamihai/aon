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
              2. enabled=0          → allow
              3. deny.local.regex   → deny  (user override)
              4. deny.regex         → deny  (HARD FLOOR — irreversible)
              5. AON_GATE_BYPASS=1  → allow (skips 6–8; floor still bites)
                  ← env var or marker file ~/.aon/security/bypass
              6. cache hit (allow only) → cached verdict
              7. allow.local.regex  → allow (user override)
              8. allow.regex        → allow (fast path)
              9. ollama classifier  → allow | deny | ask
             10. classifier deny OR ask → operator-ask over NATS
                  ← TUI / CLI replies allow|deny
                  ← timeout → fallback (ask | deny | allow)
```

**Override semantics:** classifier `deny` is *operator-overridable* — same path as `ask`. Only `deny.regex` is irreversible. Rationale: classifier can be wrong; operator can be right. If no operator listens (NATS unreachable / timeout) → fallback (`AON_GATE_FALLBACK`, default `ask`; switch to `deny` for unattended runs).

## Trust model — what this gate does and does NOT defend

The gate is **intent gating**, not isolation. Effective threat coverage depends on where the agent runs:

| Setup | Bypass meaningful? | What stops a hostile agent |
|---|---|---|
| Agent on host, no VM (local solo dev) | weak — agent can `touch ~/.aon/security/bypass` | only `deny.regex` floor (and only if agent can't edit it) |
| Agent as separate Unix user with `0700` $HOME | yes | DAC + gate |
| Agent in colima VM with AppArmor (`scripts/sandbox/`) | yes — marker on host, VM read-only mount | AppArmor + DAC + gate + IAM |

**Real defenses** under any threat model:

- `deny.regex` — only as strong as your protection of the engine repo. Mounted ro into the VM in the sandbox setup; that's the actual defense.
- AppArmor / colima VM — filesystem and syscall scope. See [`docs/sandbox.md`](../../docs/sandbox.md).
- IAM least-privilege on cloud creds — destructive verbs return access-denied even if argv slips through.
- Network egress allowlist (`nft`) — agent can't exfil.

The gate complements these, doesn't replace them. **Run agents in colima for any non-toy threat model.**

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
