---
column: Backlog
created: 2026-05-06
order: 1116
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
depends_on: aon-cmd-gate-evolve-map-elites-archive,aon-cmd-gate-evolve-runner
---

# Card — cmd-gate evolve: operator-gated champion deployment

Seventh brick. Wires the archive's champion prompts into nemotron
deployments — through an explicit operator approval, with auditable
rollout / rollback.

## Goal

```bash
aon security archive                 # list cells + champions
aon security archive show <cell>     # diff vs current deployed prompt
aon security archive deploy <cell>   # operator-confirmed deploy
aon security archive rollback        # to previous champion
```

The classifier's policy text lives in
[`scripts/security/classifier-ollama.sh`](../scripts/security/classifier-ollama.sh)
as a heredoc today. Deploy replaces that section atomically + commits
on a `security/champion-deploy-<ts>` branch (or applies as an env-
overridden prompt file, depending on operator preference).

## Deliverables

- `bin/aon` subcommands above.
- Diff is shown before confirmation — `git diff --color`-style.
- Deploy publishes `evt.security.gate.policy-change.<role>` audit
  event so deployed agents pick up the new prompt at next session
  start (per learn-from-overrides §B contract).
- Rollback is one CLI call; restores previous champion + republishes
  policy-change event.
- Deploy refuses if the candidate's `false_allow` rate (from shadow
  data, if available) exceeds the currently-deployed prompt's rate —
  unless `--force-regression` flag is set, which logs loudly.

## Acceptance

- Deploy produces a reviewable diff on stdout before prompting.
- Deploy is reversible in one command without losing audit trail.
- A deployed champion's hash is visible in `aon doctor` output so
  operators can verify what's live.
- Refusal-on-regression prevents accidental quality drops.

## Out of scope

- Auto-deploy without operator confirmation. ADR-002 §Risks
  explicitly defers this until the loop has a track record.
- Per-role champion deployments (different prompts for
  generalist/specialist/manager). Possible future extension; ship
  single-prompt-for-all-roles first.
