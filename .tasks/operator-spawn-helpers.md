---
column: Backlog
created: 2026-04-28
updated: 2026-04-28
order: 55
priority: normal
parent: onboarding-overhaul
---

# Operator-started helpers — human-in-the-loop sub-agents

The human operator starts helper Claude sessions on **their own
machine** when they decide they need parallel help. Helpers connect
to a local-only bus where the main agent (mihai) sees them.

**Crucial:** the main agent does NOT spawn, manage lifecycle,
timeout, or kill helpers. The human operator does that — by
running `claude` in another terminal and closing it when done.
Main agent only **talks to** helpers that already exist.

```
team NATS (internet, JWT-auth)
        ▲
        │
        │  main agent  (mihai on operator laptop)
        │      │
        │      └── local bus  (127.0.0.1, no auth)
        │              │
        │              ├── helper-1   (operator opened terminal A)
        │              ├── helper-2   (operator opened terminal B)
        │              └── helper-3   (operator opened terminal C)
                              ↑ each helper starts/stops with its terminal
```

## Why human-in-the-loop, not main-agent-spawn

Earlier draft had main agent calling `spawn_helper(...)`. Problems:

- Main agent has to remember to kill / clean up. LLM forgetfulness
  → orphan subprocesses, leaked tokens.
- Resource caps + timeouts have to live in the prompt.
- Lifecycle bugs invisible to operator until disk full / fan
  spinning.
- Operator already knows when help is needed; making the LLM
  decide adds latency + uncertainty.

Human-in-the-loop fixes this: operator opens a terminal, runs
`aon helper-start`, closes terminal when done. Main agent only
sees the helpers that currently exist. Lifecycle = terminal.

## Architecture

### Local bus

Operator box runs a tiny local nats-server on its own port
(e.g. `nats://127.0.0.1:42222`). Started once via
`aon helper-bus up`, runs in background. Loopback-only listener,
no auth needed.

### Subjects (local-only)

```
helpers.<helper-id>.inbox     ← main agent dispatches here
helpers.<helper-id>.events    ← helper status / progress
helpers.<helper-id>.result    ← helper publishes final output
helpers.discovery             ← helpers announce themselves on startup
```

No `agents.>` namespace on the local bus. Distinct from team NATS
to prevent confusion.

### Operator workflow

```bash
# operator one-time setup (idempotent)
aon helper-bus up

# open terminal 1 — main agent
aon launch mihai ~/Repos/saas
# claude opens; team NATS + helper-bus both attached.

# open terminal 2 — helper for python work
aon helper-start py-pal
# claude opens with helper context; auto-publishes
# {helper_id: "mihai-py-pal", role: "helper", started_by: mihai}
# to helpers.discovery, then waits for tasks on
# helpers.mihai-py-pal.inbox.

# main agent (terminal 1) sees the discovery event in monitor.
# operator types in terminal 1: "delegate task X to py-pal"
# main agent calls helper_send_task(helper="py-pal", task="X")
# → publishes to helpers.mihai-py-pal.inbox

# helper (terminal 2) processes, publishes to
# helpers.mihai-py-pal.result. main agent sees event, reads,
# integrates.

# operator closes terminal 2 when done. helper exits.
# main agent's monitor shows "helper py-pal disconnected".
```

### Helper identity

`<helper-id>` = `<owner>-<short-name>` where:
- `<owner>` = operator's main role (e.g. `mihai`).
- `<short-name>` = operator-chosen mnemonic (e.g. `py-pal`,
  `repo-reader`).

Operator picks the name when running `aon helper-start <name>`.
Forbidden names: any other team peer's role (`vahid`, `sara`, …)
to prevent confusion.

### Worktree

`aon helper-start` creates a fresh worktree off `origin/main` at
`~/.aon/helpers/<helper-id>/wt/`, branch
`<owner>/helper-<helper-id>/<auto-slug>`. Helper's claude session
starts in that directory.

Operator can override (`--cwd PATH`) for non-git work.

### Cleanup

Helper exits when operator closes the terminal (or `Ctrl-C`s
claude). On exit:
- Helper publishes `helpers.<helper-id>.events` with `kind: "exit"`.
- `aon helper-start` wrapper script removes the worktree if empty
  + branch if no commits. If commits exist on the branch, retain
  for operator review.

No automatic timeout. Operator decides when to stop.

## Main agent's role (gateway, no lifecycle)

Main agent (mihai) has:

- A monitor on `helpers.>` to see discovery + result + event
  traffic.
- MCP tools: `helper_list()`, `helper_send_task(id, task)`,
  `helper_read_result(id)`.

Main agent does NOT have:

- `spawn_helper()` — no, operator runs `aon helper-start`.
- `kill_helper()` — no, operator closes the terminal.
- Timeout / max-runtime — no, operator paces themselves.

Bridging between team NATS and helpers is the same as before:
explicit, parent decides. Default = no bridge.

## CLI surface

```
aon helper-bus up         # start local nats-server (idempotent)
aon helper-bus down       # stop local nats-server
aon helper-bus status

aon helper-start <name>   # operator runs in a fresh terminal;
                          # creates worktree, launches claude,
                          # auto-publishes discovery
```

That's it. No `spawn-helper`, no `kill-helper`, no
`list-helpers` (main agent's `helper_list()` MCP tool covers that).

## Filesystem + git boundaries

Same as the spawn-pattern draft, but enforced by the
`aon helper-start` launcher (it sets up the worktree + restricted
env), not by spawn-time wrappers:

- Worktree-only file access (worktree path is the helper's `cwd`).
- Branch-scoped commits (no `git push` from helper's git config).
- No read access to `~/.aws/`, `~/.ssh/`, parent creds, signing
  keys (env vars whitelisted at launch time).
- Handoff via branch SHA + summary, not file blobs.

## Acceptance

- Operator runs `aon helper-start py-pal` from a fresh terminal →
  helper claude opens, publishes discovery on local bus, waits.
- Main agent (mihai) sees discovery, can call
  `helper_send_task("py-pal", task)` and get a result back via
  the local bus.
- No `spawn_helper` MCP tool exposed to the main agent.
- Operator closes the helper terminal → helper exits, monitor
  sees disconnect.
- Helper subprocess connects ONLY to local bus. Trying to reach
  team NATS fails (no creds / different URL).
- Vahid (team peer on different box) sees zero helper traffic —
  even discovery.
- Multiple helpers per operator (3+ open terminals) coexist
  without collision; main agent sees all in `helper_list()`.
- Different operators on different boxes have isolated buses;
  vahid's helpers invisible to mihai.
- Helper worktree retained after exit only if commits exist on
  the branch.

## Out of scope

- Cross-machine helpers.
- Cross-operator helper sharing.
- Helper-to-helper direct comms (each helper talks to main agent
  only).
- Long-lived helpers (>1 day) — promote to real roster role via
  `aon connect`.
- **Auto-spawn / auto-kill from main agent** (separate future card:
  `headless-agent-spawn` — main agent spawns subprocess helpers
  without operator pressing buttons. Reuses helper-bus + worktree
  primitives from this card; adds spawn/lifecycle/timeout/cap.)
- Sub-helper spawning by helpers.

## Dependencies

None hard. Effectively independent of the rest of
`onboarding-overhaul`. Local bus + helper-start launcher can ship
ahead of `nsc-jwt-migration` and `waiting-room-admit`.

Soft win: post `nsc-jwt-migration`, main agent's gateway code uses
`.creds` for the team-side, simpler than password env.

## Order to do

1. `aon helper-bus up/down/status` — local nats-server lifecycle.
2. `aon helper-start <name>` — worktree + branch + launch claude
   with `AON_HELPER_ID` + helper-bus URL env. Auto-publish
   discovery on startup.
3. Main agent MCP tools: `helper_list`, `helper_send_task`,
   `helper_read_result`. Reads + writes on local bus only.
4. Smoke: operator opens 3 helper terminals, main agent dispatches
   3 different tasks, collects 3 results. Vahid (separate box)
   sees zero helper traffic.
5. Doc + example: "operator opens helper for python work, main
   agent fans out file-review tasks" walkthrough.
