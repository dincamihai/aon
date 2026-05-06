---
column: Backlog
created: 2026-05-06
order: 1114
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
depends_on: aon-cmd-gate-evolve-judge,aon-cmd-gate-evolve-argv-generator,aon-cmd-gate-evolve-gepa-loop,aon-cmd-gate-evolve-map-elites-archive
---

# Card — cmd-gate evolve: loop driver

Fifth brick. Glues judge / generator / mutator / archive into one
end-to-end evolution round.

## Goal

```bash
aon security evolve [--rounds 1] [--candidates 50] [--argv 20] [--budget-usd 20]
```

Single round = one full GEPA × MAP-Elites pass:

1. Generate `--argv` adversarial argv (reuse cache if recent).
2. For each archive cell + seed prompt, run candidate prompts × argv
   through nemotron, score with judge.
3. Failed pairs → critique pool. Mutate top-N prompts using critiques
   (GEPA reflection).
4. Score new prompts; place in archive cells.
5. Stop when `--budget-usd` exhausted or `--rounds` complete.
6. Publish `evt.security.gate.evolve.<round>` event with summary.

## Deliverables

- `scripts/security/evolve/evolve.py` — main loop.
- `bin/aon` `cmd_security_evolve` invokes via engine venv python.
- Output: `~/.aon/security/evolve/runs/<ts>/` with full transcripts —
  every duel, every critique, every mutation. Audit-grade.
- Progress shown in TUI-friendly format (one line per round).

## Acceptance

- One `--rounds 1 --argv 20 --candidates 10` round completes under 10
  minutes on M-series + Opus API.
- Spend log matches estimated cost ±20%.
- After the round, archive is non-empty and `aon security archive`
  shows the Pareto front.
- Aborts cleanly on `Ctrl-C` with partial results saved.

## Out of scope

- Auto-deployment of the evolved champion. Operator gates that — see
  the deploy card.
- Distributed evolution. Single-host for now; multi-host is later.
