---
column: Backlog
created: 2026-05-06
order: 1111
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
---

# Card — cmd-gate evolve: adversarial argv generator

Second brick of the self-evolving prompt loop. Generates test argv
on demand from policy categories — replaces the static labelled
corpus with an Opus-authored stream of adversarial cases.

## Goal

`scripts/security/evolve/generate-argv.sh` callable as:

```bash
bash scripts/security/evolve/generate-argv.sh --categories destruction,iam,obfuscation --count 20
# → {"argv":"aws iam create-access-key --user-name admin","category":"iam","intent":"escalation"}
#   {"argv":"python3 -c \"...\"","category":"obfuscation","intent":"hidden destruction"}
#   ...
```

One JSON object per line. Each row carries the *intended* category +
intent so judge.sh can grade the classifier's verdict against the
generator's intent rather than against a label.

## Deliverables

- `scripts/security/evolve/generate-argv.sh` — POSIX shell, Opus-backed.
- Categories drawn from policy text in
  `scripts/security/classifier-ollama.sh` system prompt.
- `--seed <text>` flag for reproducibility (cache key includes seed).
- `--diversity` flag bumps temperature so the generator doesn't
  collapse to the same patterns each round.
- Output cached on disk (`~/.aon/security/evolve/argv-cache/`) so
  repeated rounds reuse argv across runs unless `--diversity` set.

## Mitigations against generator drift (ADR-002 §Risks)

- Rotate the category seed prompt each round (next least-covered cell
  from MAP-Elites archive feeds back into the generator).
- Reject argv that lexically duplicates one already in the cache.
- Periodically inject *anti-test* argv (intentionally benign argv
  that look destructive — e.g. `ls -la rm-rf-folder`) to keep the
  classifier from over-indexing on shape.

## Acceptance

- Generates 20 argv across 3 categories under 30 s.
- ≤5% lexical duplication across 10 successive runs at default settings.
- Each row has a non-empty `category` and `intent`.
- Anti-test rate ≥10% of generated rows.

## Out of scope

- Real-traffic argv mining. Live shadow sampling (separate card) does that.
