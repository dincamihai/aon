---
column: Backlog
created: 2026-05-06
order: 1112
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
---

# Card — cmd-gate evolve: GEPA reflective mutator

Third brick of the self-evolving prompt loop. Wraps GEPA's
reflective mutation pattern: failed cases → judge writes a 1-line
critique → LLM rewrites the prompt with the critique in mind.

## Goal

`scripts/security/evolve/mutate.py` callable as:

```bash
python3 scripts/security/evolve/mutate.py \
  --prompt-in current.txt \
  --failures failures.jsonl \
  --critiques critiques.jsonl \
  --prompt-out v2.txt
```

Where `failures.jsonl` contains argv the candidate prompt got wrong
(per judge.sh) and `critiques.jsonl` contains the judge's 1-line
diagnosis per failure. Output is the rewritten classifier prompt.

## Deliverables

- `scripts/security/evolve/mutate.py` — uses [`gepa-ai/gepa`](https://github.com/gepa-ai/gepa) reference impl, with the Anthropic Claude provider plugged in (Opus or Sonnet 4.6 as mutator — Sonnet is fine here, judge already uses Opus).
- Reads/writes plain text prompts, not JSONL, so prompts stay diff-friendly.
- Mutator system prompt asks for *minimal* edits + a `# rationale:` tag at the bottom of the new prompt explaining what changed and why.
- Reject mutations that:
  - delete more than 30% of the prompt (probably degenerate);
  - remove a category entirely from the policy enumeration.

## Acceptance

- Given the 8 hardest PoC failures, produces a v2 prompt that beats
  v1 on at least 5 of them per judge.sh.
- Rationale tag present in v2.
- Diff between v1 and v2 < 50% of v1's line count on average.

## Out of scope

- RL-style optimisation. ADR-002 §Alternatives ruled it out (35× more
  rollouts vs GEPA per the paper).
