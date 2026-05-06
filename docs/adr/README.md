# `ai-over-nats` Architecture Decisions

Cross-cutting design decisions for the engine. Per-team specifics live
in each team-aon repo. Format follows
[`~/.claude/ORGANIZATION.md`](https://github.com/dincamihai/aon-config)
(numbered, never-reused, never-deleted; status line in each file).

## Index

| ADR | Title | Status |
|---|---|---|
| [001](001-cmd-gate-layered-safety-gate.md) | cmd-gate — layered argv-level safety gate | ACCEPTED |
| [002](002-self-evolving-classifier-prompt.md) | self-evolving classifier prompt (no labelled corpus) | PROPOSED |

## Conventions in this repo

- `001-`, `002-`, … strict numbering. Never re-used.
- Status enum: PROPOSED · ACCEPTED · DEFERRED · REJECTED · ABANDONED · SUPERSEDED-BY-ADR-MMM · SPECULATIVE · VISION.
- A decision is split into its own ADR when ≥3 ADR-worthy sub-decisions cohabit one doc, or when another part of the codebase references one of them.
- Implementation tickets live in [`.tasks/`](../../.tasks/) as cards, not in ADRs.
