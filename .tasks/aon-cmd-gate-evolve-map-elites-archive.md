---
column: Backlog
created: 2026-05-06
order: 1113
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
---

# Card — cmd-gate evolve: MAP-Elites Pareto archive

Fourth brick. Bookkeeping for the prompt archive — bucket prompts
by behaviour cell so the loop preserves diversity instead of
collapsing onto a single global maximum.

## Goal

`scripts/security/evolve/archive.py` exposes:

```python
arch.add(prompt: str, scores: dict)   # dict has fpr, fnr, p50_latency_ms, accuracy
arch.cells() -> list[Cell]            # current Pareto front
arch.champion(posture: str) -> str    # "tight", "balanced", "fast"
arch.history(n: int = 50) -> list     # last N champions for rollback
```

Each cell is `(fpr_band, fnr_band, latency_band)` — three behaviour
dimensions with discrete bands (e.g. low/med/high). Cell holds
exactly one champion: the highest-fitness prompt that lands in that
cell. Improvements within a cell replace the champion; entries in
new cells expand the archive.

## Storage

```
~/.aon/security/evolve/archive/
  cells/<fpr>-<fnr>-<lat>/champion.txt   prompt
                          /scores.json    full score vector
                          /history.jsonl  every prompt that ever landed
  index.jsonl                              one-line summary per cell
  champions.log                            deploy history (timestamp, cell, hash)
```

## Posture mapping

| Posture | Cell preference |
|---|---|
| `tight` | low FPR, accept higher FNR (deny more, possibly over-deny) |
| `balanced` | low FPR + low FNR cell with median latency |
| `fast` | low latency, accept moderate FPR/FNR |

## Acceptance

- After 10 evolution rounds, archive has ≥5 distinct cells populated.
- `archive.champion("balanced")` returns a non-empty prompt.
- Re-running evolution against an existing archive replaces only the
  champions of cells where the new prompts beat the old.
- Rollback to the previous champion is one CLI call (covered by the
  deploy card).

## Out of scope

- Tuning the band thresholds dynamically. Ship with hardcoded bands;
  revisit once the archive has data to inform reasonable cuts.
