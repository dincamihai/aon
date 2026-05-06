---
column: Backlog
created: 2026-05-06
order: 1110
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
---

# Card — cmd-gate evolve: pluggable judge (Anthropic or ollama)

First brick of the self-evolving prompt loop (ADR-002). Standalone
shell entry-point that takes (policy, argv, candidate verdicts) and
returns a JSON judgement. Backend is operator-configurable —
Anthropic API (Opus / Sonnet / Haiku) or local ollama (e.g. a model
larger than the classifier). Same JSON contract either way.

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

## Config

| Env var | Default | Notes |
|---|---|---|
| `AON_GATE_EVOLVE_BACKEND` | `anthropic` | `anthropic` \| `ollama` |
| `AON_GATE_EVOLVE_MODEL` | `claude-opus-4-7-20251001` (anthropic) / `gpt-oss:20b` (ollama) | judge model id |
| `AON_GATE_EVOLVE_OLLAMA_URL` | `http://127.0.0.1:11434` | local endpoint |
| `AON_GATE_EVOLVE_TIMEOUT_S` | `30` | per-call deadline |
| `AON_GATE_EVOLVE_BUDGET_USD` | `20` | daily cap; refuse calls past it (anthropic only) |
| `AON_GATE_EVOLVE_DIR` | `~/.aon/security/evolve` | spend log + cache live here |
| `ANTHROPIC_API_KEY` | — | required for `backend=anthropic` |

## Deliverables

- `scripts/security/evolve/_lib.sh` — backend-agnostic LLM caller
  (`evolve_call_llm`), pricing table, spend log, budget guard.
- `scripts/security/evolve/judge.sh` — input on stdin, output JSON
  on stdout. Calls `evolve_call_llm` with the judge system prompt.
- Daily spend log at `$EVOLVE_DIR/spend.log` (`anthropic` backend
  only — local model is free).
- Output schema:

```json
{"winner":"a","correct":"deny","critique":"argv contains hidden delete-objects flag",
 "category":"data destruction","unreachable":false}
```

`unreachable=true` when the judge's rationale relies on context the
classifier can't have access to — that pair is filtered from
training pairs by the GEPA loop.

## Acceptance

- `judge.sh` returns the `deny` candidate as winner on the 8 hardest
  PoC cases (psycopg2 DROP/UPDATE, char-code SQL, urlopen+exec, etc.)
  on **both** backends with appropriate models.
- Refuses on missing API key (`anthropic` backend) with clear error.
- Refuses when budget exhausted; logs to stderr.
- Spend log entries append: `ts<TAB>model<TAB>in_tok<TAB>out_tok<TAB>cost_usd`.
- Average end-to-end latency under 5 s per duel on Opus, under 3 s
  on Sonnet, under 8 s on local 20B models.

## Out of scope

- Streaming. Judge always emits a single JSON object.
- Per-team model picks. Single backend+model active per operator
  workstation; multi-team support comes later if needed.
