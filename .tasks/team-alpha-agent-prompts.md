---
column: Done
created: 2026-04-25
order: 50
---

# Agent prompts — six role briefs (maya, raj, lin, sam, diego, priya)

Per-role markdown prompts the agent reads on session start, one per role in
[MODEL.md](../MODEL.md).

## Scope

`scripts/agent-prompts/<role>.md` for: `maya.md`, `raj.md`, `lin.md`, `sam.md`,
`diego.md`, `priya.md`.

Each prompt covers, scoped to that role's domain + permissions:

1. **Identity** — name, role title, NATS user, what subjects you can publish/
   subscribe (verbatim from `team-alpha-nats-config.md` permission map).
2. **Cycle loop** — what to do each session:
   - subscribe to your inbox + relevant `board.tasks.<domain>.pending` /
     `board.learning.<domain>.pending`,
   - claim policy: pull from JetStream work-queue stream `TASKS` (or `LEARNING`),
     first-claim-wins is enforced server-side by stream retention,
   - post results to `board.results.<domain>`, update KV state,
   - DM via `agents.*.inbox` for collab, broadcast for incidents/standup.
3. **Permission boundaries** — explicit list of subjects that will reject. Tell
   agent why (e.g. Sam: "you cannot claim `board.tasks.python.pending` — that's
   production work; use `board.learning.python.pending` instead, mentor-paired").
4. **Growth track** — for non-managers: declared growth domains (per MODEL.md
   §"Permissions"), how to claim learning tasks, how to find a mentor via
   `board.learning.<domain>.mentoring`.
5. **Mentoring track** — for Raj only: how to announce availability on
   `board.learning.<domain>.mentoring`, how to handle inbox replies.
6. **Manager track** — for Maya only: posting tasks (validation gateway will
   bounce malformed), broadcast etiquette, KV writes for project state, NOT
   posting `board.results.>` (denied).
7. **Audit** — single publish to NATS; the `AUDIT` stream mirrors all subjects
   automatically. No client-side dual-write. Audit is infrastructure, not
   protocol.
8. **When to ASK** — when stuck, ambiguous spec, contradiction: DM the relevant
   specialist's inbox, OR post `board.tasks.<domain>.blocked` with the question.
   Never guess — cost of an ask is one event; cost of guessing wrong is hours of
   redo.
9. **Output** — end-of-cycle 3–5 line summary: what was claimed, what shipped,
   what's blocked.

## Files

- `scripts/agent-prompts/maya.md`
- `scripts/agent-prompts/raj.md`
- `scripts/agent-prompts/lin.md`
- `scripts/agent-prompts/sam.md`
- `scripts/agent-prompts/diego.md`
- `scripts/agent-prompts/priya.md`
- `scripts/agent-prompts/_common.md` — shared boilerplate (NATS connection,
  identity env vars, ASK rule, audit note). Each role prompt sources this via
  `<!-- include: _common.md -->` or operator concatenates at onboard time.

## Identity model (env vars)

```
TEAM_ALPHA_ROLE=<maya|raj|lin|sam|diego|priya>   # required
TEAM_ALPHA_USER=$TEAM_ALPHA_ROLE                  # NATS user
TEAM_ALPHA_NATS_URL=nats://nats.team-alpha.corp:4222
TEAM_ALPHA_CREDS=~/.team-alpha/<role>.password   # gitignored
```

Role IS identity — no separate per-instance ID. One agent per role per host.

## Acceptance

- [ ] Six role prompts written, each ≤300 lines, self-contained.
- [ ] Each prompt's permission section matches `nats-server.conf` exactly (copy-
      paste the allow/subscribe lists, no drift).
- [ ] `_common.md` extracted, no duplicated text across role files.
- [ ] Smoke test: an agent loaded with `lin.md` correctly refuses (in role-play)
      to claim `board.tasks.terraform.pending`, points to `board.tasks.{python,
      ui,go}.pending` instead.
- [ ] Mentoring & growth flows present in non-Maya prompts; manager flows
      present only in `maya.md`.
- [ ] No client-side audit duplication — prompts say "publish to NATS, AUDIT
      stream handles persistence".
