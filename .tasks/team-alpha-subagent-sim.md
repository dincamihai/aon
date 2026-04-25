---
column: Backlog
created: 2026-04-25
order: 65
---

# Subagent simulation — six Claude subagents play the team

After config + bootstrap + onboard + prompts + hooks land, drive the substrate
with six Claude Code subagents (one per role) and watch coordination emerge.
Validates the design end-to-end before exposing it to humans.

## Goal

Run a scripted scenario where Maya posts work, specialists claim it, a
cross-functional task triggers DMs, a learning task gets mentored, an incident
broadcast is handled. Capture the AUDIT stream as a transcript.

## Scope

`scripts/sim/` directory:

- `sim/spawn.sh <role>` — spawns a Claude Code subagent via the `Agent` tool with:
  - the role's prompt (`scripts/agent-prompts/<role>.md`)
  - env vars `TEAM_ALPHA_ROLE=<role>`, NATS URL, creds path
  - background mode so all six run concurrently
- `sim/scenarios/` — markdown scenarios. Each scenario describes initial state
  (what Maya posts, KV seed) and expected emergent behavior:
  - `01-normal-task.md` — Maya posts terraform task; Raj or Priya claims; result
    posted; KV updated. Pass = exactly one claim, one result, audit shows full
    chain.
  - `02-cross-functional.md` — fullstack task. One claimer + 2 inbox DMs to
    specialists. Pass = inbox round-trips visible.
  - `03-learning-mentor.md` — Raj announces mentoring; Lin claims learning task;
    pairing happens. Pass = `board.learning.go.mentoring` and
    `board.learning.go.claimed` both fire.
  - `04-permission-reject.md` — Sam tries to claim `board.tasks.python.pending`
    (denied). Pass = NATS rejects; agent falls back to `board.learning.python.>`.
  - `05-incident.md` — Priya broadcasts incident; Raj DMs offer; resolution
    flows. Pass = broadcast received by all six, DM exchange in audit.
- `sim/run.sh <scenario>` — orchestrates: seeds KV, spawns six subagents,
  triggers scenario action, captures AUDIT stream for N minutes, kills agents,
  produces report.
- `sim/report.py` — reads AUDIT stream snapshot, renders timeline of events
  (per role), highlights expected vs missing events for the scenario.

## Subagent spec per role

Preferred: use Claude Code's experimental **Teams** feature
(`Agent({team_name: "team-alpha", subagent_type: "<role>"})`) — declares the
six roles as a persistent team, each role definition pinned to its prompt +
allowed tools. Subagents run concurrently, addressable via `SendMessage` for
inter-agent coordination outside the NATS substrate (sim orchestration only —
real comms still goes through NATS).

Fallback if Teams unavailable: spawn six independent `Agent(subagent_type:
general-purpose)` calls in one message, each loaded with the role prompt as
system context.

Either way, each subagent:
- loaded with role prompt as system context
- has `Bash` access to run `nats pub` / `nats sub` / KV commands using its
  role's password
- runs in background, emits events to NATS as it works
- terminates when scenario timer expires or scenario sends `broadcast.sim.stop`

## Teams setup

`scripts/sim/team.yaml` (or whatever Teams config format ships with):
- team name: `team-alpha`
- six role definitions: `maya`, `raj`, `lin`, `sam`, `diego`, `priya`
- each role: prompt path, tool allow list (`Bash` + `nats` cmd allowlist), env
  template (role, NATS URL, creds path)
- isolation: each subagent in its own worktree to keep file edits scoped (Claude
  Code Teams supports `isolation: worktree`).

## Files

- `scripts/sim/spawn.sh`
- `scripts/sim/run.sh`
- `scripts/sim/report.py`
- `scripts/sim/scenarios/{01..05}-*.md`
- `docs/simulation.md` — how to run, how to read reports.

## Acceptance

- [ ] `bash scripts/sim/run.sh 01-normal-task` completes in ≤5min, prints
      pass/fail, leaves a transcript file.
- [ ] All five scenarios pass on a clean substrate.
- [ ] Permission-reject scenario (#4) shows server rejection in NATS log AND
      the agent's prompt-aware fallback to learning subject.
- [ ] Report renders per-role timeline + missing/unexpected event diffs.
- [ ] Sim is idempotent — running twice produces equivalent transcripts (modulo
      timestamps and which generalist claims first).

## Depends_on

`team-alpha-nats-config`, `team-alpha-docker-compose`, `team-alpha-bootstrap`,
`team-alpha-onboard`, `team-alpha-agent-prompts`, `team-alpha-hooks`.

## Out of scope

- Replacing real human team interaction with permanent subagents — this is a
  validation harness, not the product.
- Multi-host deployment — sim runs against single docker-compose stack.
