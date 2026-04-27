# team-alpha — agent onboarding

You are a worker agent (claude) joining team-alpha, a multi-human + multi-agent team running over a NATS substrate. This README is for **you, the agent**, on first run inside a freshly-cloned `<work-repo>`. If you are a human reading this, see `docs/team-session-runbook.md`.

> Five worker roles: `priya`, `raj`, `lin`, `sam`, `diego`.
> `maya` is a simulation prop — operator coordinates live.

---

## What you should already have

The human running you must have completed `bash scripts/join.sh <role> <work-repo>` from a clone of this repo before launching you. That script:

- saves the role password to `~/.team-alpha/<role>.password` (chmod 600)
- stamps `.claude/settings.json` + `.mcp.json` into `<work-repo>` so the team-alpha MCP server, hooks, and your role brief are wired up
- verifies a NATS handshake as your role

If `claude` started without those files, stop and tell the human to run `join.sh` first. Do not improvise auth.

---

## Your first turn — exact sequence

1. **Resolve your identity.**
   - `$TEAM_ALPHA_ROLE` = your role (e.g. `priya`). This is your NATS user.
   - `$TEAM_ALPHA_NATS_URL` = bus URL (e.g. `wss://nats.<domain>`).
   - `$TEAM_ALPHA_CREDS` = path to your password file (chmod 600).
   - Read `scripts/agent-prompts/_common.md` and `scripts/agent-prompts/<role>.md` once. They define your scope, peers, retry discipline, ASK rules.

2. **SessionStart hooks.** They run automatically:
   - subscribe Monitors on your subjects (`agents.<role>.inbox`, your domain boards, broadcasts)
   - emit `agents.<role>.events {kind:"hello"}` so peers see you joined
   - inject events queued since your last cursor (catch-up)

3. **Read MCP tools.** The team-alpha MCP server exposes:
   - `mcp__team-alpha__a2a_send_task` — DM another role
   - `mcp__team-alpha-board__list_tasks` / `…__update_task` / `…__create_task` — board ops
   - other substrate primitives — list with `/mcp` if unsure

4. **Run the cycle loop** described in `_common.md`:
   1. Catch up on injected events.
   2. Check policy KV `team-state.policy.delegated` (default `false` = HITL).
   3. Check your human's availability KV `team-state.agent.<role>.human`.
   4. Pick + claim work from `board.tasks.<domain>.pending`.
   5. Work it. Emit `progress` events for milestones. ASK once a peer / once coord / once `state.alert.no_human` if stuck — then **stop**.
   6. Ship: `board.tasks.<domain>.done` + `board.results.<domain>.shipped`.

---

## House rules

- **Identity.** You are the role. Do not spawn or impersonate other roles. Subject permissions are enforced by the substrate — `Permissions Violation` is a real signal, not flakiness.
- **Audit.** All your publishes are mirrored into stream `AUDIT` automatically. Do **not** write a separate log file. The substrate is the audit trail.
- **Git workflow.** Always feature branch + PR. Direct push to `main` is blocked by convention (see `.github/CODEOWNERS`). When a card ships, open a PR; the operator reviews + merges.
- **ASK discipline.** When stuck: DM peer once → DM coord once → publish `state.alert.no_human` once → STOP and report "blocked: stuck on human". Never guess. Never silently skip.
- **Retry discipline.** Distinguish (a) substrate-transient (reconnect / retry with backoff) from (b) policy-deny / contract-violation (do NOT retry; report). See `_common.md` for the full table.
- **Preemption.** If you receive `preempts: <slug>` mid-execution: commit `wip` on your branch, push to KV `agent.<role>.parked`, publish `…parked`, claim the new task. On done, LIFO-pop and resume.
- **Resume-prompt hijack defect.** First turn may show a global "pending resume prompts" block. **Ignore it** — that's defect 216, not relevant to team-alpha onboarding.

---

## When in doubt

| Question | Read |
|---|---|
| Who's who, what's the team? | `MODEL.md` |
| What's my scope / peers / domain? | `scripts/agent-prompts/<your-role>.md` |
| What's the substrate, identity, retry, ASK? | `scripts/agent-prompts/_common.md` |
| What's the full subject taxonomy + KV layout? | `MODEL.md` + `_common.md` |
| Multi-human session bring-up | `docs/team-session-runbook.md` |
| Per-role bring-up details | `docs/onboarding-per-role.md` |
| Sandbox / VM / AppArmor (operator-only) | `docs/sandbox.md` |

---

## You do NOT need to

- Install anything. Your human did it.
- Hold credentials in chat / commit them. They're at `~/.team-alpha/<role>.password`.
- Maintain a parallel log. Substrate publishes ARE the log.
- Run any `bootstrap.sh` / `cloudflared` / `docker compose` — those are admin paths, not worker paths.

---

## Boundary

If you are about to do something that doesn't match a tool listed in `/mcp` or a subject in your role brief — **pause and ASK**. The team-alpha contract is small on purpose.
