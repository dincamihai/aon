# ADR-001 · cmd-gate — layered argv-level safety gate

**Status:** ACCEPTED
**Date:** 2026-05-05

## Summary

Agents in `aon` launch with `claude --dangerously-skip-permissions`, so Claude Code's built-in permission prompts are off. We need an argv-level layer that catches destructive commands before they hit the host shell. cmd-gate is that layer: a layered PreToolUse hook that combines fast deterministic regex with a local LLM classifier (`nemotron-3-nano:4b`) for ambiguous argv, with operator approval over NATS for anything the classifier flags. It complements — not replaces — the colima/AppArmor sandbox, IAM least-priv, and network egress allowlists.

## Decision

Ship a per-call PreToolUse hook (`scripts/hooks/pre-tool-use.sh` → `scripts/security/cmd-gate.sh`) that runs a 9-step layered pipeline:

1. tool != Bash (or path tool with credential path) → allow / deny credential paths
2. enabled=0 → allow
3. `deny.local.regex` (user override) → deny
4. `deny.regex` (HARD FLOOR — irreversible) → deny
5. `AON_GATE_BYPASS=1` (env or `~/.aon/security/bypass` marker) → allow (skips 6–8; floor still bites)
6. cache hit (allow only) → cached verdict
7. `allow.local.regex` (user override) → allow
8. `allow.regex` (fast path) → allow
9. ollama classifier → `allow` | `deny` | `ask`. Both `deny` and `ask` route to operator-ask over NATS (TUI / CLI). Timeout → fallback (`ask` | `deny` | `allow`, configurable).

The hook publishes audit envelopes on `evt.security.gate.<role>`. Operator approval round-trips via `evt.coord-in.gate-request.<role>.<id>` → `evt.coord-out.gate-reply.<role>.<id>`. Per-role NATS ACLs prevent agents from impersonating peers or self-approving.

## Impact

- Agents launched via `aon launch` now go through the gate by default after `aon admin hooks install` populates `<work_repo>/.claude/settings.json`.
- Operators run a textual TUI (`aon security watch`) to approve/deny ambiguous calls, or use `aon security {pending,approve,deny}` from scripts.
- Personal regex overrides (`~/.aon/security/{allow,deny}.local.regex`) and a hard bypass marker support the local-dev workflow without weakening the deny.regex floor.
- New NATS subjects added; auth templates updated; existing teams need to delete + re-mint user JWTs once.

## Context

### What problem

A misbehaving (or compromised) agent on the operator's host can run any shell command. The colima/AppArmor sandbox ([`docs/sandbox.md`](../sandbox.md)) provides filesystem and syscall isolation but cannot tell `aws s3 ls` from `aws s3 rm` or `SELECT` from `DROP TABLE`. We need an argv-level layer that reads command intent.

### Constraints

- Per-Bash-call latency budget: agents already wait seconds for each Bash; <300 ms typical, <3 s worst-case acceptable.
- No mandatory cloud dependency — must work fully offline (operator's laptop in solo dev).
- Operator must always have an override path; deny.regex hard floor must be the only thing they can't lift.
- ACLs must prevent agent self-approval and peer impersonation.
- Existing aon roles (manager / generalist / specialist / sysadmin) must not need redesign.

### Alternatives considered

- **Bubblewrap / AppArmor only** — wrong granularity. Path/syscall scoping cannot tell `aws s3 ls` from `aws s3 rm`. Already deployed as outer ring; intent gating is a separate job.
- **IAM-only** — necessary defense-in-depth, but doesn't help with `rm -rf`, `git push --force`, prod-DB writes, or anything outside the cloud-API surface.
- **Hosted classifier (Haiku)** — better quality but adds cost, latency, and a network dependency. Local nemotron is good enough (PoC: 42/42 verdicts) and free.
- **BERT classifier** — wrong tool. Brittle on novel argv, requires labelled corpus, can't reason about hidden flags. LLM reads intent; classifier just matches surface.
- **Claude Code built-in permissions** — agent runs with `--dangerously-skip-permissions` for autonomy; can't put that toothpaste back without breaking the agent loop.

## Implementation

### File layout

```
scripts/security/
  _lib.sh                      shared env + helpers
  cmd-gate.sh                  layered entry
  classifier-ollama.sh         argv → JSON via /api/generate
  cache.sh                     sha256(argv) → verdict, TTL'd
  audit.sh                     publish to evt.security.gate.<role>
  operator-ask.sh              NATS request / await reply
  policy/
    allow.regex                fast-path safe argv
    deny.regex                 hard-floor destructive argv
  POC-CLASSIFIER-CASES.md      42-case PoC reference corpus
  README.md                    design + ops doc
scripts/hooks/
  pre-tool-use.sh              Claude Code hook entry
  install.sh                   wires PreToolUse into .claude/settings.json
  tests/
    test-cmd-gate.sh           unit tests (no ollama, 25 cases)
    test-cmd-gate-classifier.sh integration test (live ollama, 8 cases)
bin/
  aon                          `aon security {watch,pending,approve,deny,bypass,cache}` + doctor checks
  aon-security-watch           textual TUI
  _aon-lib.sh                  NATS NSC user perms (per-role gate-request/reply ACL)
templates/
  security/policy.toml.example knobs
```

### NATS subjects + ACL

| Subject | Direction | Permitted |
|---|---|---|
| `evt.security.gate.<role>` | gate → operator (audit) | agent: pub own; sysadmin: sub all |
| `evt.coord-in.gate-request.<role>.<id>` | agent → operator | agent: pub own; sysadmin: sub all |
| `evt.coord-out.gate-reply.<role>.<id>` | operator → agent | sysadmin: pub all; agent: sub own |

Per-role qualifier (`<role>`) closes the impersonation gap: an agent's NATS user can only publish on its own gate-request namespace, only subscribe to its own reply path. sysadmin (the human operator account) holds wildcards. ACL definitions live in [`bin/_aon-lib.sh::_aon_nsc_ensure_user`](../../bin/_aon-lib.sh) with a matching signature mirror in `_aon_nsc_acl_sig` for drift detection.

### Operator UX

```
aon security watch              live textual TUI
aon security pending            JSON list of waiting requests
aon security approve <role> <id> [reason]
aon security deny    <role> <id> [reason]
aon security bypass on|off|status
aon security cache  status|clear
aon doctor                      checks ollama + model + policy files
```

### Override hierarchy

```
deny.local.regex            user, always-deny (highest)
deny.regex                  HARD FLOOR — irreversible, not lifted by bypass
AON_GATE_BYPASS=1           skips classifier + allow layers (deny floor still bites)
allow.local.regex           user, always-allow
allow.regex                 fast path
classifier (ollama)         allow | deny | ask
operator-ask (TUI/CLI)      allow | deny via NATS
```

### Tests

- 25/25 unit tests (`test-cmd-gate.sh`) — regex layers, bypass, cache, fallback, path-tool credential checks.
- 8/8 integration tests (`test-cmd-gate-classifier.sh`) — live ollama on the hidden-flag, char-code SQL, urlopen+exec, executemany cases.
- 42/42 PoC corpus documented in `scripts/security/POC-CLASSIFIER-CASES.md` — exhaustive reference for prompt tuning.

## Consequences

### What changes

- Every Bash call from an agent goes through the gate. ~5 ms regex, ~2 s classifier on ambiguous, blocking on operator-ask for the rare `ask` verdict.
- Operator runs a permanent TUI (or stays available to approve via CLI) for unattended agent runs to make progress.
- Existing teams must delete + re-mint user JWTs once to pick up the new NATS perms.
- `aon launch` warms the model (`keep_alive=24h`) so the first ambiguous Bash doesn't pay the ~6 s ollama cold start.

### Risks

- **Overzealous classifier denies** — mitigated by operator-overrideable deny path (only `deny.regex` is irreversible) and by personal `allow.local.regex`.
- **Operator unavailable** — fallback `AON_GATE_FALLBACK` (default `ask` shown to agent; switch to `deny` for unattended runs).
- **Bypass is honor-system on bare host** — agent can `touch ~/.aon/security/bypass`. Mitigated by colima/AppArmor sandbox, where the marker lives outside the VM. Documented in the README's trust-model section.
- **Static prompt drift** — addressed by ADR-002 (self-evolving prompt).

### What we gave up

- Per-Bash latency adds ~2 s on classifier-touched calls. Acceptable: Bash calls are seconds anyway, regex pre-filter handles the common case in <5 ms.
- Cache caches `allow` only — `deny`/`ask` re-route every time so operator can change their mind. Slightly wasted classifier cycles in exchange for correctness.

## References

- [`scripts/security/README.md`](../../scripts/security/README.md) — operational doc
- [`scripts/security/POC-CLASSIFIER-CASES.md`](../../scripts/security/POC-CLASSIFIER-CASES.md) — 42-case corpus
- [`docs/sandbox.md`](../sandbox.md) — outer-ring colima/AppArmor design
- Cards: [`aon-cmd-gate-ollama-classifier`](../../.tasks/aon-cmd-gate-ollama-classifier.md), [`aon-cmd-gate-acl-update`](../../.tasks/aon-cmd-gate-acl-update.md), [`aon-cmd-gate-learn-from-overrides`](../../.tasks/aon-cmd-gate-learn-from-overrides.md)
- ADR-002 (PROPOSED) — self-evolving classifier prompt
