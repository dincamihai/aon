---
column: Backlog
created: 2026-05-06
order: 1103
priority: medium
parent: aon-cmd-gate-ollama-classifier
adr: ADR-002
type: epic
---

# Epic — `aon` cmd-gate: self-evolving classifier prompt (no corpus)

> **Status:** epic, broken into 7 sub-cards. See ADR-002
> ([`docs/adr/002-self-evolving-classifier-prompt.md`](../docs/adr/002-self-evolving-classifier-prompt.md))
> for the architectural rationale and cost model.

## Sub-cards (sequenced)

| # | Card | Concern |
|---|---|---|
| 1 | [`aon-cmd-gate-evolve-judge`](aon-cmd-gate-evolve-judge.md) | Opus judge invoker (`scripts/security/evolve/judge.sh`) |
| 2 | [`aon-cmd-gate-evolve-argv-generator`](aon-cmd-gate-evolve-argv-generator.md) | Adversarial argv generator |
| 3 | [`aon-cmd-gate-evolve-gepa-loop`](aon-cmd-gate-evolve-gepa-loop.md) | GEPA reflective mutator |
| 4 | [`aon-cmd-gate-evolve-map-elites-archive`](aon-cmd-gate-evolve-map-elites-archive.md) | Pareto archive + cells |
| 5 | [`aon-cmd-gate-evolve-runner`](aon-cmd-gate-evolve-runner.md) | Loop driver (`aon security evolve`) |
| 6 | [`aon-cmd-gate-evolve-shadow`](aon-cmd-gate-evolve-shadow.md) | Live disagreement sampling + drift alarm |
| 7 | [`aon-cmd-gate-evolve-deploy`](aon-cmd-gate-evolve-deploy.md) | Operator-gated champion deployment |

Sub-cards 1–4 are independently shippable bricks. 5 glues them. 6
adds drift detection. 7 is the operator-facing deploy gate. Cards 5
and 7 depend on the bricks; 6 only needs the judge.

Asked while implementing the gate: *"can we use MAP-Elites / GEPA to
evolve the classifier prompts? I don't want to build and maintain a
corpus."* — i.e. tune the policy prompt without the operator hand-
labelling argv as allow / deny.

This card replaces the labelled-corpus assumption with **LLM-judge
pairwise comparison** (SPO/PDO style), wraps it in **GEPA reflective
mutation**, and keeps a Pareto front via **MAP-Elites** so we
preserve diverse trade-offs (low FPR vs low FNR vs low latency).

## Why no corpus

- Maintaining a labelled corpus is the highest-friction part of any
  prompt-eval loop. Policy drifts; new argv categories appear monthly.
- LLM-judge replaces "ground truth" with on-demand pairwise preference.
  Same policy text feeds both classifier (nemotron) and judge (Opus).
- Operator overrides are still captured by
  [`aon-cmd-gate-learn-from-overrides`](aon-cmd-gate-learn-from-overrides.md)
  — but as **priority duels** in the evolution stream, not as a static
  corpus. Rare, high-signal, never lost; never required.

## Algorithm

```
adversarial argv generator (Opus)
  ├─ seeded with policy text + category list
  ├─ generates argv covering: destruction, IAM, schema, obfuscation,
  │  hidden flags, char-code SQL, prod-DSN, network exfil, novel...
  ↓
candidate classifier prompts (initial seed = current hand prompt)
  ↓
nemotron-3-nano:4b runs each candidate × each argv → verdict
  ↓
Opus judge:
  reads (policy, argv, candidate-A verdict, candidate-B verdict)
  picks the more correct one OR flags both wrong (mutation signal)
  ↓
GEPA reflective mutate:
  failed cases → judge writes a 1-line critique → LLM rewrites prompt
  ↓
MAP-Elites archive:
  bucket by (FPR-band, FNR-band, latency-band)
  keep best-fitness prompt per cell
  ↓
Operator picks deployment posture:
  "tight & slow" / "fast & permissive" / "balanced"
  → that cell's champion prompt deploys to nemotron
```

No labelled file ever appears. Validation is live: a small fraction
of production argv get shadow-judged by Opus; disagreement rate is
the drift signal that triggers re-evolution.

## Pieces

```
scripts/security/evolve/
  generate-argv.sh        Opus → adversarial argv (with category)
  judge.sh                Opus → JSON verdict + critique
  evolve.py               GEPA loop + MAP-Elites archive
  archive/                cell → champion prompt + scores (jsonl)
  shadow.sh               live-traffic disagreement sampler
bin/aon
  cmd_security_evolve     run one evolution round
  cmd_security_archive    show Pareto front, pick champion to deploy
```

## Cost (Opus 4.7 1M context, May 2026 pricing)

| Phase | Approx call count | Cost |
|---|---|---|
| One evolution round (50 candidates × 20 argv × 1 judge) | 1000 calls | ~$15 |
| Weekly evolution | 4/mo | ~$60/mo |
| Live shadow validation (1% of Bash, ~100/day) | 30/day | ~$5/mo |

Tractable for a team. Drops to ~$10/mo total if evolved monthly
+ shadow at 0.5% sample rate.

## Open questions

1. **Argv generator drift.** Adversarial generator may collapse to a
   narrow distribution. Mitigate: seed each round with a different
   category prompt from the policy; rotate.
2. **Judge–classifier scale gap.** Opus catches things nemotron
   never will; classifier evolves toward an unreachable target.
   Bound by: only count the judge correct when its rationale would
   plausibly fit in nemotron's prompt window. Filter unreachable
   wins from training pairs.
3. **Live shadow sampling.** 1% sample = quiet, but slow drift
   detection. Tune up to 5% during initial deployment, drop later.
4. **MAP-Elites cells.** Three behavior dims feels right (FPR, FNR,
   latency). Could add "category coverage" as a 4th — prompts that
   handle all 8 policy categories beat narrow specialists.
5. **Champion deployment.** Auto-deploy from Pareto front, or
   gate behind operator approval? Operator approval first; auto-
   deploy once track record is solid.

## Acceptance

- One evolution round, no corpus on disk, produces a Pareto front
  of ≥5 distinct prompts spanning the FPR/FNR/latency cells.
- Replaying the 42 PoC cases against the evolved champion matches
  or beats the hand-prompt baseline.
- Live shadow detects a regression (judge–classifier disagreement
  >5%) within 24h of policy drift, triggers re-evolution.
- Cost stays under $100/mo at standard cadence.

## Out of scope

- Fine-tuning nemotron itself. Prompt-only optimization first; weights
  are a follow-up if the prompt ceiling is hit.
- Replacing the classifier model. Same `nemotron-3-nano:4b` target
  throughout — we're tuning the prompt, not the model.

## References

- [GEPA — Reflective Prompt Evolution Can Outperform RL](https://arxiv.org/abs/2507.19457) (ICLR 2026 oral)
- [GEPA reference impl](https://github.com/gepa-ai/gepa)
- [SPO — Self-Supervised Prompt Optimization](https://arxiv.org/abs/2502.06855)
- [PDO — LLM Prompt Duel Optimizer (dueling bandit, label-free)](https://arxiv.org/abs/2510.13907)
- Parent: [`aon-cmd-gate-ollama-classifier`](aon-cmd-gate-ollama-classifier.md)
- Sibling: [`aon-cmd-gate-learn-from-overrides`](aon-cmd-gate-learn-from-overrides.md) — operator approvals feed this loop as priority duels.
