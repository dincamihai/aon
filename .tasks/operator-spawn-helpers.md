---
column: Backlog
created: 2026-04-28
order: 55
priority: normal
parent: onboarding-overhaul
depends_on: waiting-room-admit
---

# Operator-spawned ephemeral helpers — short-lived sub-agents

Any human-operated agent on the team (mihai, vahid, sara, …) can
spin up N sub-agents on demand for parallel work on **their own
machine**, without editing `aon.toml` or bouncing NATS per spawn.
Helpers inherit an owner-scoped namespace + ACL, do one task,
terminate.

Spawning is a property of being human-operated (the operator drives
the parent session), not a property of role kind. A specialist or
generalist can spawn helpers just as a manager can.

## Today's pain

Spawning a helper currently requires:

1. Edit `aon.toml` (add role).
2. `aon creds <name>` + `aon auth render`.
3. `aon nats down && aon nats up` (ACL reload).
4. `aon launch <name> <work-repo>`.

Steps 1-3 are not per-spawn ephemeral. Roster bloats, NATS bounce
disrupts every other agent on the substrate. Cannot scale to "spawn
5 helpers, run 30s, terminate".

## End state (post waiting-room)

```bash
# any human-operated agent session (e.g. vahid)
aon spawn-helper --task "summarize repo X" --timeout 5m
# → mints helper credential via waiting-room admit
#   (auto-approved because parent has spawn-helper privilege)
# → helper claude session boots in a tmpdir worktree, runs the task
# → publishes result to agents.vahid.helpers.<id>.result
# → parent subscribes, collects, terminates helper
# → creds revoked (nsc revocations add-user)
```

Inline equivalent for code paths:

```python
# from any operator-driven MCP session (mihai, vahid, sara…)
result = spawn_helper(task="...", timeout="5m", model="haiku-4.5")
```

## Architecture

### Helper namespace (owner = parent role)

Each helper gets a UUID-suffixed name, scoped under whoever spawned
it (the "owner"):

```
helper-id    = <owner>-helper-<uuid8>
inbox        = agents.<helper-id>.inbox
events       = agents.<helper-id>.events
result       = agents.<owner>.helpers.<helper-id>.result
```

Owner's ACL extended: pub/sub on `agents.<owner>.helpers.>`.
Helper's ACL: pub on `agents.<owner>.helpers.<self>.result` ONLY,
plus full pub/sub on its own inbox/events.

Helper CANNOT DM other peers, cannot read other helpers' results
(even within the same owner), cannot post to `board.>`.
Locked-down "scratch agent".

### Spawn flow

1. Parent session calls `aon spawn-helper` (CLI or MCP tool).
   Parent role = `$AON_ROLE`.
2. aon mints a JWT under the team account with helper-scoped
   permissions targeted at `agents.<parent-role>.helpers.>`
   (using NSC, post-`nsc-jwt-migration`).
3. aon launches a Claude subprocess with `AON_ROLE=<helper-id>`,
   `NATS_CREDS=<helper.creds>`, in a tmp worktree off `origin/main`.
4. Helper's first turn: pick up task from `agents.<helper-id>.inbox`
   (parent publishes task as the spawn happens).
5. Helper does work. Final action: publish to
   `agents.<owner>.helpers.<helper-id>.result`. Exit.
6. Parent's monitor sees the result event. aon detects exit, runs
   `nsc revocations add-user <helper-id>` + cleans tmpdir.

### Lifecycle states

- **spawning**: creds minted, subprocess starting.
- **working**: subprocess up, processing.
- **done**: result published, subprocess exiting.
- **revoked**: creds invalidated, tmpdir cleaned.
- **timeout**: max-runtime exceeded. Parent kills + revokes.

State held in KV `agent.<owner>.helpers.<helper-id>` for resume
across parent restart.

## ACL design (post-NSC)

Single template `helper.tmpl` consumed by NSC user creation:

```
allow_pub:    agents.<self>.events, agents.<owner>.helpers.<self>.result, _INBOX.>
allow_sub:    agents.<self>.inbox, _INBOX.>
deny_pub:     agents.<other>.>, board.>, broadcast.>, state.>
allow_pub_response: true
```

`<self>` and `<owner>` substituted at JWT creation time. `<owner>`
is whichever role spawned this helper.

### Spawn privilege

Spawning is gated by parent being human-operated, not by role kind.
Implementation: ACL allows pub on the spawn-trigger subject
(`team.<team>.spawn-request`) for every roster role EXCEPT roles
flagged `kind: helper` in NSC tags. This explicitly denies
recursive sub-helper spawning — helpers cannot spawn their own
helpers.

## CLI surface

```
aon spawn-helper [--task TEXT] [--timeout DURATION] [--model NAME] [--cwd PATH]
aon list-helpers [--owner ROLE]   # default: $AON_ROLE
aon kill-helper <helper-id>
```

MCP tool wrapper (available to any non-helper role): `spawn_helper(task,
timeout, model)` returns `{helper_id, result_subject, tmp_path}`.

## Acceptance

- Any roster role (mihai, vahid, sara …) — regardless of kind —
  can spawn helpers without `aon.toml` edits or NATS bounce.
- Helpers spawned by vahid land under `agents.vahid.helpers.>`,
  not under another role.
- Helper completes a task, publishes result, terminates inside its
  timeout budget.
- Helper credentials revoked post-exit; `nats sub agents.<helper-id>.inbox`
  rejects after revocation.
- Helper attempting to DM another peer (e.g. mihai) gets
  permission violation.
- Helper attempting to spawn its own helper gets permission
  violation (recursion blocked).
- Parent can `aon kill-helper <id>` mid-flight; helper subprocess
  receives SIGTERM, JWT revoked.
- `aon list-helpers` shows lifecycle state + age scoped to caller.
- Concurrent spawns by the same parent (5+) don't race on JWT
  minting or tmpdir allocation.
- Concurrent spawns by different parents (mihai + vahid) get
  isolated namespaces.

## Out of scope

- Cross-owner helper sharing (each parent owns its own helpers).
- Helper-to-helper communication (helpers are independent units).
- Sub-helper spawning (helpers cannot recursively spawn) — explicit
  ACL deny on the spawn trigger subject.
- Long-lived helpers (>1h) — those should become real roster roles.
- GPU / heavy-compute helpers — same code path but operator decides
  on the spawn host.
- Cross-host helper spawn (helpers run on parent's machine).

## Dependencies

- **Hard**: `nsc-jwt-migration` lands first (need ephemeral JWT
  minting + revocation).
- **Hard**: `waiting-room-admit` lands first (provides the
  encrypt-creds-to-pubkey delivery primitive helpers reuse).
- **Soft**: `streamline-aon-join #11` (pre-seed task card) — same
  task-handoff mechanism could feed helper's first-turn task.

## Order to do (post deps)

1. Helper-scoped JWT template + NSC mint helper.
2. `aon spawn-helper` CLI: mint, launch, monitor, revoke on exit.
3. Parent-side `spawn_helper()` MCP tool wrapper.
4. KV state for helper lifecycle (resume across parent restart).
5. `aon list-helpers` + `aon kill-helper`.
6. Smoke test: 5 concurrent helpers per parent + 2 parents
   spawning concurrently, all complete, all revoked.
7. Doc + example: "operator dispatches 5 file-review helpers in
   parallel" pattern.
