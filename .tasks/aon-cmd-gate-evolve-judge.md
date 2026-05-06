---
column: Backlog
created: 2026-05-06
order: 1110
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
---

# Card — cmd-gate evolve: Opus judge

First brick of the self-evolving prompt loop (ADR-002). A standalone
shell entry-point that takes (policy, argv, candidate verdicts) and
returns a JSON judgement using Opus 4.7 (1M context).

## Goal

`scripts/security/evolve/judge.sh` invokable as:

```bash
echo '{"argv":"...","verdicts":[{"prompt_id":"a","verdict":"deny","reason":"..."},
                                 {"prompt_id":"b","verdict":"allow","reason":"..."}]}' \
  | bash scripts/security/evolve/judge.sh
# → {"winner":"a","correct":"deny","critique":"argv contains hidden delete-objects flag",
#    "category":"data destruction","unreachable":false}
```

`unreachable=true` when the judge's rationale relies on context the
classifier (nemotron-3-nano:4b) doesn't have access to — that pair is
filtered from training pairs.

## Deliverables

- `scripts/security/evolve/judge.sh` — POSIX shell calling Anthropic API.
- Reads `ANTHROPIC_API_KEY` from env (operator-side; not for agents).
- Hardcoded model: `claude-opus-4-7` (1M context, prompt-cached system).
- Prompt-caches the policy text + judging instructions so repeated
  duels in one round are cheap.
- Budget guard: read `AON_EVOLVE_BUDGET_USD` env, refuse if cumulative
  spend in current round exceeds.

## Acceptance

- `judge.sh` returns the `deny` candidate as winner on the 8 hardest
  PoC cases (psycopg2 DROP/UPDATE, char-code SQL, urlopen+exec, etc).
- Refuses on missing API key with clear error.
- Cumulative spend log under `~/.aon/security/evolve/spend.log`.
- Average end-to-end latency under 5 s per duel (cached prompt).

## Out of scope

- Local judge model. Opus is the explicit choice (ADR-002 §Alternatives).
