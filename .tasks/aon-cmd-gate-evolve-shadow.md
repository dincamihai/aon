---
column: Backlog
created: 2026-05-06
order: 1115
priority: medium
parent: aon-cmd-gate-self-evolving-prompt
adr: ADR-002
depends_on: aon-cmd-gate-evolve-judge
---

# Card — cmd-gate evolve: live shadow validation

Sixth brick. Continuous drift detection on the deployed prompt
without a held-out corpus. Samples a fraction of live argv, runs
the Opus judge against the classifier's verdict, tracks
disagreement rate.

## Goal

`scripts/security/evolve/shadow.sh` is a long-running daemon (or
LaunchAgent / systemd unit) that:

1. Subscribes to `evt.security.gate.>` audit stream.
2. Samples ~1% of audited verdicts (configurable via
   `AON_GATE_SHADOW_RATE`).
3. For each sampled verdict, calls `judge.sh` with the same argv.
4. Compares classifier verdict vs judge verdict.
5. Appends to `~/.aon/security/evolve/shadow.jsonl`.
6. Maintains a 24h rolling disagreement rate.
7. When disagreement rate crosses a threshold (default 5%), publishes
   `evt.security.gate.drift-alert.<role>` and (optionally) auto-fires
   `aon security evolve --rounds 1` if `AON_GATE_SHADOW_AUTO_EVOLVE=1`.

## Deliverables

- `scripts/security/evolve/shadow.sh` — POSIX, runnable as daemon.
- LaunchAgent plist + systemd service template under
  `templates/security/shadow.{plist,service}.tmpl` for operator
  installation.
- `aon security shadow {start|stop|status}` subcommands.
- Disagreement reasons categorised: `false_allow` (classifier
  allowed, judge would deny — high severity), `false_deny`
  (classifier denied, judge would allow — UX irritation), `agree`
  (no signal, drop from log).

## Acceptance

- 24h shadow run on a synthesised stream of mixed argv produces a
  `disagreement.jsonl` populated with both `false_allow` and
  `false_deny` entries.
- Drift alert fires when disagreement crosses threshold.
- `false_allow` rate is alert-priority (red); `false_deny` is
  warn-priority (yellow).
- Daemon costs ≤ $5/mo at 1% sampling on a typical 100-call/day
  team.

## Out of scope

- Full transparent shadow proxy of every Bash. Cost-prohibitive and
  unnecessary — sampling has good statistical properties.
- Active learning from disagreements (operator-curated). The learn-
  from-overrides card covers the rare-but-real-world version of
  this signal.
