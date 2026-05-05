---
column: Backlog
created: 2026-05-05
order: 1102
priority: medium
parent: aon-cmd-gate-ollama-classifier
---

# Card — `aon` cmd-gate: learn from operator overrides

Asked while implementing the gate: *"would it be possible to make some
rejected patterns as safe?"* — i.e. when the operator approves a
classifier-deny via the TUI, can the gate remember that decision so the
operator isn't asked again for the same argv?

This card adds a feedback loop from operator decisions into the gate's
allow/deny lists, with safeguards.

## Goal

Operator approves an argv via TUI → next time the same argv (or near-
duplicate) appears, gate auto-allows without prompting. Same path for
"deny + reason → suggest a personal deny pattern."

## Design

### Two storage layers

- **Per-argv cache** (already exists): exact-match `sha256(argv) → verdict`. Survives restarts, 1 h TTL. Already auto-populates on classifier-allow.
- **Pattern suggestions** (new): when operator overrides on multiple
  argv that share a stem, gate proposes a regex line for
  `~/.aon/security/allow.local.regex` (or `deny.local.regex`).

### Flow

1. Operator presses `y` on a classifier-deny in the TUI.
2. Watcher publishes reply with `decision=allow`. Gate audits and
   serves the call.
3. Watcher *also* records the (argv, role, classifier-prior, operator)
   tuple to `~/.aon/security/decisions.jsonl`.
4. Background pass (`aon security learn`) reads `decisions.jsonl`,
   clusters by argv prefix / shell verb, and proposes regex lines.
5. TUI surfaces "you've approved 3 similar `npm install ...` commands —
   add `^npm install\b` to allow.local.regex? [y/n/edit]". If accepted,
   appends to `~/.aon/security/allow.local.regex`.

### Safeguards

- **Never auto-add patterns.** Always require a second-keystroke
  confirmation. Operator owns the personal regex files.
- **deny.regex is unaffected.** Operator overrides cannot suggest
  weakening the hard floor — overrides on argv that hit the floor are
  blocked at the previous layer (the floor is checked before the
  operator path).
- **Cluster threshold.** Don't propose a pattern after a single
  approval. Wait for ≥3 distinct argv that share a normalized prefix.
- **Time-decay.** Old approvals (>30d) drop out of the suggestion
  pool. Operator preferences shift; don't treat last quarter's hot-fix
  as policy.
- **Audit always.** Every pattern addition logs to
  `evt.security.gate.policy-change` with operator identity, source argv
  list, and proposed regex.

## Files

```
scripts/security/
  decisions.sh                NEW — append + read decisions.jsonl
  learn.sh                    NEW — cluster + propose patterns
bin/aon                       EDIT — `aon security learn` subcommand
bin/aon-security-watch        EDIT — record decision on each y/n,
                              show "suggest pattern?" prompt when
                              cluster threshold hits
```

## Open design questions

1. **Granularity of clustering.** First word? First two words? Token
   ngrams? Start with first-word + first-flag prefix; tune.
2. **Where to surface suggestions.** Inline in TUI vs separate
   `aon security learn` interactive command. TUI inline is more
   discoverable but interrupts approval flow. Suggest separate command,
   with a counter in the TUI footer ("3 patterns ready: aon security learn").
3. **Per-role patterns.** Should approvals from operator decisions
   apply only to the role that originated the request? Or globally?
   Probably per-role: the same argv from a `dba` role and an
   `architect` role have different risk. Default: per-role allow,
   shared deny.
4. **Conflicts with existing rules.** If operator's proposed allow.local
   would shadow an existing deny.regex match, refuse — show why.

## Out of scope

- Embedding-based clustering (use kNN over embeddings of past approvals
  for "this looks like X you approved before"). Worth exploring once
  the simple prefix-cluster has data showing where it's wrong.
- ML-driven personalized classifier (fine-tune a small model on the
  operator's approval history). Over-engineering until we know the
  operator-approval rate is high enough to matter.

## Acceptance

- After 3 approvals of `npm install <pkg>` with different `<pkg>`,
  `aon security learn` proposes `^npm install\b`.
- Operator types `y` → `~/.aon/security/allow.local.regex` gains the
  line. Next `npm install` doesn't reach classifier; audit shows
  `layer=allow.local`.
- Operator types `n` → suggestion dropped. Re-clusters next time.
- Override on `rm -rf /` is impossible (deny.regex caught it before
  operator path) — so no learning data exists. Safe.

## References

- [`.tasks/aon-cmd-gate-ollama-classifier.md`](aon-cmd-gate-ollama-classifier.md) — parent
- [`scripts/security/cache.sh`](../scripts/security/cache.sh) — the per-argv layer this builds on top of
