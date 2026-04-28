---
column: Backlog
created: 2026-04-28
updated: 2026-04-28
order: 55
priority: normal
parent: onboarding-overhaul
---

# Operator-spawned ephemeral helpers — gateway pattern

Any human-operated agent on the team (mihai, vahid, sara, …) can
spin up N sub-agents on their **own machine** to do parallel work.

**Key design**: helpers do NOT connect to the team NATS. They
talk only on a **local-only bus** to the parent agent. The parent
is the **gateway** — selectively forwards/translates between team
NATS and local helpers. Helpers never see other team peers'
messages and other team peers never see helpers exist.

```
team NATS (internet, JWT-auth)
        ▲
        │
        │  parent agent  (mihai on his laptop)
        │      │
        │      └── local NATS  (127.0.0.1, no auth needed)
        │              │
        │              ├── helper-1
        │              ├── helper-2
        │              └── helper-3
```

## Why gateway, not extended-ACL helpers

Earlier draft proposed: helpers join team NATS with restricted JWT
ACL. Problems:

1. **Roster pollution**: every spawn = new entry in some directory.
2. **Internet exposure**: helpers running random LLM-generated code
   are reachable from the team NATS account. Lateral risk if a
   helper goes off-script.
3. **JWT mint+revoke per spawn**: cost + delay per ephemeral.
4. **Visibility leak**: even with deny-pub on `agents.<other>.>`, a
   helper still sees subject metadata in violation errors,
   broadcast announce ACK, etc. Defense-in-depth weak.

Gateway pattern fixes all four:

- Helpers never hit the team NATS. Zero attack surface to the
  team.
- No JWT mint/revoke. Local NATS uses no auth or a static local
  cred file (chmod 600).
- No team-NATS roster bloat. Helpers exist only on the operator's
  machine.
- Parent decides what helpers see. Selective forwarding =
  least-privilege by default.

## Architecture

### Local bus

Operator box runs a tiny local nats-server on a non-team port
(e.g. `nats://127.0.0.1:42222`, distinct from team's
`nats://localhost:4222` if both share a host).

Spun up by `aon helper-bus up` (or auto-started by first
`aon spawn-helper`). Loopback-only listener. No public exposure.
No auth needed (loopback + chmod 600 socket if Unix domain socket
preferred).

### Subjects (local-only)

```
helpers.<helper-id>.inbox    ← parent dispatches task here
helpers.<helper-id>.events   ← helper progress / status
helpers.<helper-id>.result   ← helper final output
```

No `agents.>` namespace on the local bus. No risk of confusing
local with team subjects.

### Spawn flow

1. Parent session calls `aon spawn-helper` (CLI / MCP tool).
2. aon ensures helper-bus is up; mints local-only client cred
   (Unix-socket perms or token written to tmpfile).
3. aon launches a Claude subprocess with:
   - `AON_HELPER_ID=<owner>-helper-<uuid8>`
   - `AON_HELPER_BUS=nats://127.0.0.1:42222`
   - tmp worktree off `origin/main`
4. Helper's first turn: read task from
   `helpers.<helper-id>.inbox`. Do work.
5. Helper publishes result to `helpers.<helper-id>.result`. Exit.
6. aon detects exit, cleans tmpdir, removes local cred. No
   team-NATS revoke needed (helper never had team creds).

### Parent as gateway

Parent's session (mihai) holds two connections:

- Team NATS (`agents.mihai.inbox`, `board.>`, etc.) — JWT auth
- Local helper bus (`helpers.>`) — local cred

Parent code (or MCP tool wrapper) decides what to bridge:

- **Outbound** (team → helpers): explicit forwarding only. e.g.,
  parent receives a board task, calls `helper.dispatch(task)` →
  publishes to `helpers.<id>.inbox`.
- **Inbound** (helpers → team): explicit forwarding only. Parent
  reads helper result, packages it, publishes to wherever on team
  NATS (e.g. `board.results.<domain>.shipped`, or DM to vahid as
  the parent's own message).

Default = no bridging. Helpers see only what parent feeds them.
Team peers see only what parent re-publishes.

## Filesystem + git work

Helpers do real work on real files (git repos, other artifacts).
Constraints:

### Workspace = isolated git worktree (always)

- Each helper gets a fresh worktree off `origin/main` at
  `~/.aon/helpers/<helper-id>/wt/`.
- Branch name: `<owner>/helper-<helper-id>/<short-task-slug>`.
- Helpers commit on that branch. Pre-commit hooks run as normal.
- Disk: use `git worktree add` against an existing local clone so
  history is shared; only the working tree is duplicated. 5
  helpers ≠ 5 full clones.

### What helpers can do

- Read + write inside their worktree.
- `git commit` on their branch.
- Read-only access to env (HOME, PATH) is fine; secret-bearing
  files (`~/.aon/teams/<team>/creds/*`, `~/.aws/`, `~/.ssh/`,
  parent's `.git/config` user.signingKey) must be **excluded** via
  the helper's launcher env or filesystem sandboxing where
  available.

### What helpers CANNOT do

- `git push` (parent reviews, parent pushes).
- Touch files outside the worktree (enforced by prompt; verified
  by post-spawn diff check — see Acceptance).
- Run arbitrary shell on parent's git config or other repos.
- Network calls outside the local helper-bus + standard package
  registries (npm/pip/etc.) — implementation-dependent, document
  the chosen sandbox boundary in S2 of this card.

### Handoff = branch SHA, not file blob

Helpers publish their result as `{branch, head_sha, summary, files_touched[]}`
on `helpers.<id>.result`. Parent inspects:
- `git diff main...<branch>` for review.
- `git log <branch>` for audit.
- Either cherry-pick / rebase onto parent's working branch, or
  open a PR for human review, or discard.

This solves the audit-gap concern: git log on the branch is the
durable record of what the helper changed. No need to mirror
file-edit events into NATS.

### Cleanup

- On helper exit (success/timeout/kill): worktree retained on disk
  until parent collects the result, then `git worktree remove` +
  branch deletion (unless parent pushed the branch).
- On parent crash: `aon list-helpers --orphan` finds worktrees
  whose parent PID is dead; `aon cleanup-orphans` reaps them.
- Disk quota: per-parent cap on concurrent helper worktrees
  (`AON_HELPER_MAX=5` default). Refuse spawn over cap.

## CLI surface

```
aon helper-bus up         # start local nats-server (idempotent)
aon helper-bus down       # stop local nats-server
aon helper-bus status     # show port + age + helper count

aon spawn-helper [--task TEXT] [--timeout DURATION] [--model NAME]
aon list-helpers          # local helpers spawned by this session
aon kill-helper <helper-id>
```

MCP tool wrapper for the parent agent:

```
spawn_helper(task, timeout, model)  → {helper_id, result_subject}
helper_result(helper_id, timeout)   → {result, exit_code, duration}
helper_kill(helper_id)              → ok
```

The MCP tool encapsulates the bus connection so the parent agent
doesn't manage NATS clients directly.

## Acceptance

- Any roster role (mihai, vahid, sara …) — regardless of kind —
  can spawn helpers without `aon.toml` edits or team-NATS bounce.
- Helper subprocess connects ONLY to local helper-bus. `nats sub
  agents.>` from the helper times out / refuses connect.
- Vahid (peer on team NATS) does NOT see anything published by
  mihai's helpers — even broadcast probes.
- Mihai's helpers do NOT see vahid's DMs or any team subjects.
- Parent's MCP tool is the only path for cross-bus messages.
- Helper terminates on completion or timeout; tmpdir + local cred
  cleaned.
- Concurrent spawns by same parent (up to `AON_HELPER_MAX`) and by
  different parents on different boxes work without collision.
- Helper-bus runs on its own port, doesn't conflict with team NATS
  if both on same host.

### Git / file boundaries

- Helper worktree exists at `~/.aon/helpers/<id>/wt/` after spawn,
  on a fresh branch off `origin/main`.
- Helper commits stay on that branch. `git push` from helper
  rejected (no push perms in helper's git config).
- Post-spawn diff check (in smoke): touch a sentinel file outside
  the worktree from inside the helper subprocess → must fail or be
  caught by linter; sentinel must remain unchanged.
- Helper has no read access to `~/.aws/`, `~/.ssh/`, parent's
  `~/.aon/teams/*/creds/`, parent's `~/.gitconfig` signing keys.
  Smoke verifies via attempted-read failure.
- Parent can review helper's branch (`git diff main...<branch>`)
  before deciding to merge / cherry-pick / discard.
- `aon cleanup-orphans` reaps worktrees whose parent PID is dead.
- Refuse spawn over `AON_HELPER_MAX` cap.

## Out of scope

- Cross-machine helper sharing (helpers run on parent's box).
- Cross-operator helper sharing (each operator gateway is
  independent).
- Helper-to-helper communication (independent units).
- Sub-helper spawning by helpers (no `aon spawn-helper` access
  inside helper subprocess; MCP tool simply not registered there).
- Long-lived helpers (>1h) — promote to real roster role with team
  creds via the normal `aon connect` path.
- GPU / heavy-compute helpers — same code path, operator picks
  spawn host.

## Dependencies

- **Soft**: `nsc-jwt-migration` — parent uses team JWT for team
  NATS; helpers don't need JWT at all. Card can land before NSC
  cutover but parent's bridging code is simpler with `.creds`.
- **Soft**: `waiting-room-admit` — orthogonal; helpers bypass it
  entirely (no admit flow needed for local-only creds).

Effectively independent of the rest of `onboarding-overhaul` once
basic local-NATS scaffolding is in place.

## Order to do

1. `aon helper-bus up/down/status` — local nats-server lifecycle.
2. `aon spawn-helper` CLI — mint local cred, launch subprocess,
   monitor exit, clean.
3. Parent-side MCP tool wrapper (`spawn_helper`, `helper_result`,
   `helper_kill`).
4. Selective bridge example: parent receives a board task, fans
   out to N helpers, aggregates results, publishes summary back
   to team.
5. Smoke: spawn 5 helpers, vahid (on a separate box) confirms zero
   visibility into mihai's local bus traffic.
6. Doc + example: "5 parallel file reviews via helpers" pattern.
