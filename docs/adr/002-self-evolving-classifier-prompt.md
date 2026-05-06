# ADR-002 · self-evolving classifier prompt (no labelled corpus)

**Status:** PROPOSED
**Date:** 2026-05-06

## Summary

cmd-gate's classifier prompt today is hand-written. As policy evolves and adversaries find new obfuscations, that prompt drifts out of date — the standard fix is "build and maintain a labelled corpus", which is precisely the failure mode we want to avoid (high friction, decays fast). This ADR proposes a corpus-free alternative: an **LLM-judge (Opus) loop** that pairs argv generation, GEPA reflective prompt evolution, and MAP-Elites diversity preservation. No labels are ever maintained on disk; live operator overrides feed the loop as priority duels.

## Decision

Adopt a corpus-free evolutionary loop for the cmd-gate classifier prompt:

1. **Adversarial argv generator (Opus)** — seeded with policy text + category list, produces test argv on demand.
2. **Pairwise judge (Opus)** — reads `(policy, argv, candidate-A verdict, candidate-B verdict)` and picks the more correct response (per [SPO](https://arxiv.org/abs/2502.06855) / [PDO](https://arxiv.org/abs/2510.13907)).
3. **GEPA reflective mutator** — failed cases get a 1-line natural-language critique from the judge; an LLM rewrites the prompt accordingly ([GEPA](https://arxiv.org/abs/2507.19457)).
4. **MAP-Elites archive** — bucket prompts by behaviour cell (FPR-band × FNR-band × latency-band); keep the best-fitness prompt per cell.
5. **Champion deployment** — operator picks a posture ("tight", "balanced", "fast") from the Pareto front; the cell's champion deploys to nemotron.
6. **Live shadow validation** — sample ~1% of production argv, judge them with Opus, track disagreement rate. Spike → trigger re-evolution.

Operator overrides captured in [`aon-cmd-gate-learn-from-overrides`](../../.tasks/aon-cmd-gate-learn-from-overrides.md) feed the loop as priority duels — rare, high-signal, real-world.

## Impact

- Classifier prompt updates without manual corpus maintenance.
- Estimated cost: ~$60–100/mo per team at weekly evolution + 1% shadow sampling. Tractable on Opus 4.7 (1M context) pricing.
- Operator gets a Pareto front of prompts to choose from, not a single black-box change.
- Drift detection becomes automatic: live disagreement-rate alarms trigger evolution.
- New tooling under `scripts/security/evolve/`; `aon security evolve` and `aon security archive` subcommands.

## Context

### What problem

The hand-written classifier prompt has three failure modes:

- **Policy drift.** Operator changes what counts as "destructive" (e.g., adds prod-DB protection); prompt isn't refreshed.
- **Adversarial drift.** New obfuscation patterns appear (today char-code SQL; tomorrow something we haven't seen).
- **Model drift.** Upgrading nemotron to a newer release changes its behaviour; old prompt may regress.

The conventional answer — keep a labelled eval corpus and CI on it — is itself the high-friction part. Labels rot; categories shift; people stop maintaining the corpus and the eval becomes lying.

### Constraints

- Must work without an external labelled dataset.
- Cost ceiling ~$100/mo per team at typical traffic.
- Champion deployments must be reviewable (operator is the picker, not the optimiser).
- Cannot regress the deny.regex hard floor — only the classifier prompt is in scope.

### Alternatives considered

- **Stay hand-written.** Status quo. Works until it doesn't; failure mode is silent regression on novel argv.
- **Maintain labelled corpus.** High operational cost; corpus quality decays; team-specific patterns get lost.
- **Fine-tune nemotron.** Out of scope — prompt-only optimisation first, weights later if prompt ceiling is hit.
- **MIPROv2 / DSPy with labels.** Same corpus problem; better optimiser doesn't solve the data-rot issue.
- **RL with classifier-as-reward.** ~35× more rollouts than GEPA per the GEPA paper; cost-prohibitive at our scale.
- **Smaller cloud judge (Sonnet/Haiku).** Quality gap between judge and classifier matters — the bigger the judge, the higher-signal the disagreements. Opus 4.7 (1M context) at the suggested cadence is affordable.

## Implementation

This is a multi-stage build. Tracked as cards in `.tasks/`:

| Card | Concern |
|---|---|
| [`aon-cmd-gate-evolve-judge`](../../.tasks/aon-cmd-gate-evolve-judge.md) | Opus judge invoker (`scripts/security/evolve/judge.sh`) |
| [`aon-cmd-gate-evolve-argv-generator`](../../.tasks/aon-cmd-gate-evolve-argv-generator.md) | Adversarial argv generator (`scripts/security/evolve/generate-argv.sh`) |
| [`aon-cmd-gate-evolve-gepa-loop`](../../.tasks/aon-cmd-gate-evolve-gepa-loop.md) | GEPA reflective mutator wrapper |
| [`aon-cmd-gate-evolve-map-elites-archive`](../../.tasks/aon-cmd-gate-evolve-map-elites-archive.md) | Pareto-archive bookkeeping |
| [`aon-cmd-gate-evolve-runner`](../../.tasks/aon-cmd-gate-evolve-runner.md) | Driver: `aon security evolve` |
| [`aon-cmd-gate-evolve-shadow`](../../.tasks/aon-cmd-gate-evolve-shadow.md) | Live disagreement sampling + drift alarm |
| [`aon-cmd-gate-evolve-deploy`](../../.tasks/aon-cmd-gate-evolve-deploy.md) | Operator-gated champion deployment |

### File layout (target)

```
scripts/security/evolve/
  judge.sh                Opus → JSON verdict + critique
  generate-argv.sh        Opus → adversarial argv (with category)
  mutate.py               GEPA reflective mutator
  archive.py              MAP-Elites cell bookkeeping
  evolve.py               full loop driver
  shadow.sh               live-traffic disagreement sampler
  archive/                cell → champion prompt + scores (jsonl)
bin/aon
  cmd_security_evolve     run one evolution round
  cmd_security_archive    show Pareto front, pick champion to deploy
```

### Cost model (Opus 4.7 1M context, May 2026)

| Phase | Calls | Cost |
|---|---|---|
| Evolution round (50 candidates × 20 argv × 1 judge) | 1000 | ~$15 |
| Weekly evolution | 4/mo | ~$60/mo |
| Live shadow validation (1% of Bash, ~100/day, 30/day judged) | 900/mo | ~$5/mo |

Total ~$65/mo per team at standard cadence; drops to ~$10/mo with monthly evolution + 0.5% shadow.

## Consequences

### What changes

- A new `scripts/security/evolve/` tree with judge/generator/loop tooling.
- Operators subscribe to `evt.security.gate.policy-change.<role>` (per the learn-from-overrides card) so deployed agents pick up new prompts on the next session.
- The 42-case PoC corpus (`scripts/security/POC-CLASSIFIER-CASES.md`) becomes a *seed regression set*, not a maintenance burden — it stays static; the live loop is what drifts.

### Risks

- **Judge–classifier scale gap** — Opus catches things nemotron will never catch; the loop pursues an unreachable target. Mitigation: filter training pairs where the judge's rationale exceeds nemotron's prompt-window or capacity.
- **Generator drift** — adversarial generator collapses to a narrow distribution. Mitigation: rotate category prompts each round; seed with policy categories the model under-covered last round.
- **Auto-deploy hazard** — evolved prompt regresses live. Mitigation: operator-gated deploy (no auto-deploy until the loop has a track record); keep last-N champion prompts in archive for instant rollback.
- **Cost surprise** — judge calls cost real money. Mitigation: hard `AON_EVOLVE_BUDGET_USD` cap per round; back-off on disagreement-rate stable.

### What we gave up

- Determinism. Hand-written prompt was reproducible; evolved prompts are stochastic. Mitigation: archive every champion with its score vector + judge transcripts so any deploy can be audited.
- Simplicity. Adds 7 new files plus an operator workflow. Justified only if the maintenance burden of a hand-written prompt + manual corpus exceeds this loop's $60/mo + operator review time.

## References

- [GEPA — Reflective Prompt Evolution Can Outperform RL](https://arxiv.org/abs/2507.19457) (ICLR 2026 oral)
- [GEPA reference impl](https://github.com/gepa-ai/gepa)
- [SPO — Self-Supervised Prompt Optimization](https://arxiv.org/abs/2502.06855)
- [PDO — LLM Prompt Duel Optimizer (label-free dueling bandit)](https://arxiv.org/abs/2510.13907)
- [SPICE — Self-Play in Corpus Environments](https://arxiv.org/html/2510.24684v1)
- ADR-001 — cmd-gate layered safety gate (parent decision)
- Sibling: [`aon-cmd-gate-learn-from-overrides`](../../.tasks/aon-cmd-gate-learn-from-overrides.md) — operator approvals feed this loop as priority duels
