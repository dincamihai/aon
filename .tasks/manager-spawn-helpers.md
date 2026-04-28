---
column: Backlog
created: 2026-04-28
order: 55
priority: normal
parent: onboarding-overhaul
depends_on: waiting-room-admit
---

# Manager-spawned ephemeral helpers — short-lived sub-agents

Lets a manager role (e.g. mihai) spin up N sub-agents on demand for
parallel work, without editing `aon.toml` or bouncing NATS per spawn.
Helpers inherit a manager-scoped namespace + ACL, do one task,
terminate.

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
# manager session (mihai)
aon spawn-helper --task "summarize repo X" --timeout 5m
# → mints helper credential via waiting-room admit (auto-approved
#   because manager has spawn-helper privilege)
# → helper claude session boots in a tmpdir worktree, runs the task
# → publishes result to agents.mihai.helpers.<id>.result
# → manager subscribes, collects, terminates helper
# → creds revoked (nsc revocations add-user)
```

Inline equivalent for code paths:

```python
# from mihai's MCP tool
result = spawn_helper(task="...", timeout="5m", model="haiku-4.5")
```

## Architecture

### Helper namespace

Each helper gets a UUID-suffixed name, scoped under the manager:

```
helper-id    = mihai-helper-<uuid8>
inbox        = agents.<helper-id>.inbox
events       = agents.<helper-id>.events
result       = agents.mihai.helpers.<helper-id>.result
```

Manager's ACL extended: pub/sub on `agents.<mihai>.helpers.>`.
Helper's ACL: pub on `agents.mihai.helpers.<self>.result` ONLY,
plus full pub/sub on its own inbox/events.

Helper CANNOT DM other peers, cannot read other helpers' results,
cannot post to `board.>`. Locked-down "scratch agent".

### Spawn flow

1. Manager calls `aon spawn-helper` (CLI or MCP tool).
2. aon mints a JWT under the team account with helper-scoped
   permissions (using NSC, post-`nsc-jwt-migration`).
3. aon launches a Claude subprocess with `TEAM_ALPHA_ROLE=<helper-id>`,
   `NATS_CREDS=<helper.creds>`, in a tmp worktree off `origin/main`.
4. Helper's first turn: pick up task from `agents.<helper-id>.inbox`
   (manager publishes task as the spawn happens).
5. Helper does work. Final action: publish to
   `agents.mihai.helpers.<helper-id>.result`. Exit.
6. Manager's monitor sees the result event. aon detects exit, runs
   `nsc revocations add-user <helper-id>` + cleans tmpdir.

### Lifecycle states

- **spawning**: creds minted, subprocess starting.
- **working**: subprocess up, processing.
- **done**: result published, subprocess exiting.
- **revoked**: creds invalidated, tmpdir cleaned.
- **timeout**: max-runtime exceeded. Manager kills + revokes.

State held in KV `agent.<manager>.helpers.<helper-id>` for resume
across manager restart.

## ACL design (post-NSC)

Single template `helper.tmpl` consumed by NSC user creation:

```
allow_pub:    agents.<self>.events, agents.<manager>.helpers.<self>.result, _INBOX.>
allow_sub:    agents.<self>.inbox, _INBOX.>
deny_pub:     agents.<other>.>, board.>, broadcast.>, state.>
allow_pub_response: true
```

`<self>` and `<manager>` substituted at JWT creation time.

## CLI surface

```
aon spawn-helper [--task TEXT] [--timeout DURATION] [--model NAME] [--cwd PATH]
aon list-helpers [--manager MIHAI]
aon kill-helper <helper-id>
```

MCP tool wrapper: `spawn_helper(task, timeout, model)` returns
`{helper_id, result_subject, tmp_path}`.

## Acceptance

- Manager can spawn N helpers without `aon.toml` edits or NATS
  bounce.
- Helper completes a task, publishes result, terminates inside its
  timeout budget.
- Helper credentials revoked post-exit; `nats sub agents.<helper-id>.inbox`
  rejects after revocation.
- Helper attempting to DM another peer (e.g. vahid) gets permission
  violation.
- Manager can `aon kill-helper <id>` mid-flight; helper subprocess
  receives SIGTERM, JWT revoked.
- `aon list-helpers` shows lifecycle state + age.
- Concurrent spawns (5+) don't race on JWT minting or tmpdir
  allocation.

## Out of scope

- Cross-manager helper sharing (each manager spawns their own).
- Helper-to-helper communication (helpers are independent units).
- Sub-helper spawning (helpers cannot recursively spawn) — explicit
  ACL deny on the spawn tool's required pub.
- Long-lived helpers (>1h) — those should become real roster roles.
- GPU / heavy-compute helpers — same code path but operator decides
  on the spawn host.

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
3. Manager-side `spawn_helper()` MCP tool wrapper.
4. KV state for helper lifecycle (resume across manager restart).
5. `aon list-helpers` + `aon kill-helper`.
6. Smoke test: 5 concurrent helpers, all complete, all revoked.
7. Doc + example: "manager dispatches 5 file-review helpers in
   parallel" pattern.
