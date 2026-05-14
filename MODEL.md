Excellent — let's design this concretely. I'll model a realistic full-stack team and show how the NATS substrate supports both how they *currently* work and how they *grow*.

## The team

Let's say:

- **Maya** — Manager. Coordinates, reviews, unblocks. Some hands-on Python/AWS background.
- **Raj** — Senior generalist. Strong in Terraform, AWS, Python, Go. Comfortable anywhere.
- **Lin** — Mid generalist. Python + UI, learning Go.
- **Sam** — Specialist. Deep UI (React, design systems). Wants to learn backend.
- **Diego** — Specialist. Deep Go + backend. Wants to learn infra.
- **Priya** — Specialist. Deep Terraform + AWS. Wants to learn Python.

Six humans (or AI agents modeling them — same design either way). Mixed capability, mixed growth ambition.

## Subject taxonomy

```
org.team.alpha.>                       ← account/namespace for this team

agents.<id>.inbox                      ← direct asks (request/reply)
agents.<id>.events                     ← agent's outbound announcements

board.tasks.<domain>.<state>           ← work bulletin board
  domains: terraform, python, go, aws, ui, fullstack, review
  states:  pending, claimed, blocked, done

board.results.<domain>                 ← finished work, readable by all

board.learning.<domain>.pending        ← stretch tasks for skill growth
board.learning.<domain>.mentoring      ← "I'll mentor someone on this"

broadcast.standup                      ← daily sync announcements
broadcast.incidents                    ← something is on fire

state.project.<id>                     ← KV: project status, owner, blockers
state.agent.<id>.load                  ← KV: who's busy, who's free
state.agent.<id>.skills                ← KV: declared skills + growth goals

audit.>                                ← mirror of everything for replay
```

The key design move: **separate `board.tasks.<domain>` from `board.learning.<domain>`**. Regular tasks need to ship; learning tasks are deliberately stretch work where speed isn't the goal. Same substrate, different intent encoded in the subject.

## Permissions — modeling capability and growth

This is where it gets interesting. Each person has two sets of permissions: **what they can do today** and **what they're growing into**. Both are encoded directly.

### Maya (manager)

```yaml
publish:
  - "agents.*.inbox"                   # can DM anyone
  - "broadcast.>"                      # can announce
  - "board.tasks.*.pending"            # can post tasks in any domain
  - "board.tasks.review.>"             # can request reviews
  - "state.project.>"                  # owns project state
subscribe:
  - ">"                                # sees everything
deny_publish:
  - "board.results.>"                  # doesn't post results, the doers do
```

Maya's role: **post tasks, watch state, broadcast, unblock**. She subscribes broadly because her job is situational awareness.

### Raj (senior generalist)

```yaml
publish:
  - "agents.*.inbox"
  - "board.tasks.*.claimed"            # can claim any domain
  - "board.tasks.*.blocked"
  - "board.tasks.*.done"
  - "board.results.>"                  # can post results in any domain
  - "board.learning.*.mentoring"       # can offer mentoring in any domain
subscribe:
  - "agents.raj.inbox"
  - "board.tasks.*.pending"            # sees all pending work
  - "board.learning.*.pending"
  - "broadcast.>"
```

Raj can pick up *anything*. The permissions reflect that. He can also **mentor** in any domain — the `board.learning.*.mentoring` permission encodes seniority.

### Lin (mid generalist, learning Go)

```yaml
publish:
  - "agents.*.inbox"
  - "board.tasks.python.{claimed,blocked,done}"
  - "board.tasks.ui.{claimed,blocked,done}"
  - "board.tasks.go.{claimed,blocked,done}"   # ← growth domain, allowed
  - "board.results.python.>"
  - "board.results.ui.>"
  - "board.results.go.>"
  - "board.learning.go.claimed"               # can claim Go stretch tasks
subscribe:
  - "agents.lin.inbox"
  - "board.tasks.{python,ui,go}.pending"
  - "board.learning.go.>"                     # watches Go learning channel
  - "broadcast.>"
```

Lin's permissions explicitly include Go — both regular tasks (she can claim them, paired with a mentor) and learning tasks. The system *enables* her growth instead of gatekeeping it.

### Sam (UI specialist, growing into backend)

```yaml
publish:
  - "agents.*.inbox"
  - "board.tasks.ui.{claimed,blocked,done}"
  - "board.results.ui.>"
  - "board.learning.python.claimed"           # stretch only, not main board
  - "board.learning.go.claimed"
subscribe:
  - "agents.sam.inbox"
  - "board.tasks.ui.pending"                  # main work: UI
  - "board.learning.{python,go}.pending"      # stretch: backend
  - "board.learning.{python,go}.mentoring"    # finds mentors
  - "broadcast.>"
```

Sam **cannot** claim regular `board.tasks.python.pending` — that would block production work on someone still learning. But Sam **can** claim `board.learning.python.pending`, which by convention is scoped, mentored, and not on the critical path. The permissions encode: *grow, but don't block delivery*.

### Diego (Go specialist, growing into infra)

```yaml
publish:
  - "agents.*.inbox"
  - "board.tasks.go.{claimed,blocked,done}"
  - "board.results.go.>"
  - "board.learning.{terraform,aws}.claimed"
subscribe:
  - "agents.diego.inbox"
  - "board.tasks.go.pending"
  - "board.learning.{terraform,aws}.>"
  - "broadcast.>"
```

Same shape as Sam, different domain.

### Priya (Terraform/AWS specialist, learning Python)

```yaml
publish:
  - "agents.*.inbox"
  - "board.tasks.{terraform,aws}.{claimed,blocked,done}"
  - "board.results.{terraform,aws}.>"
  - "board.learning.python.claimed"
subscribe:
  - "agents.priya.inbox"
  - "board.tasks.{terraform,aws}.pending"
  - "board.learning.python.>"
  - "broadcast.>"
```

## How the flows actually play out

**A normal task arrives.** Maya posts:

```
publish board.tasks.terraform.pending
  { task_id: T-401, summary: "Add VPC peering for staging", priority: medium }
```

Subscribers to `board.tasks.terraform.pending`: Raj and Priya. Either can claim. The work-queue stream guarantees only one of them gets it. Sam, Diego, Lin literally don't see it — their subscriptions don't include it. No ambiguity, no stepping on toes.

**A cross-domain task.** Maya posts to `board.tasks.fullstack.pending` for "Build user settings page with backend." Raj can claim solo; or Lin claims and pairs with Sam (UI) and Diego (Go) via direct inbox messages. The board enables work; the inboxes enable collaboration.

**A growth opportunity.** Raj has time, posts:

```
publish board.learning.go.mentoring
  { mentor: raj, available_hours: 4, topics: ["concurrency", "interfaces"] }
```

Lin and Diego both see it (Diego is already a Go specialist but might still pair). Lin DMs Raj's inbox: "I'd love to pair on the goroutine task." Raj posts a learning task:

```
publish board.learning.go.pending
  { task_id: L-22, summary: "Refactor worker pool", mentor: raj, scope: 4h }
```

Lin claims it. Sam *also* sees this and could claim — Sam is allowed to. The learning board is a shared growth resource.

**Specialist grows into adjacent domain.** Priya wants Python practice. She watches `board.learning.python.pending`. Lin or Raj posts a small Python task there — maybe extracting a CLI tool from a larger codebase. Priya claims it, gets review from Lin. Over weeks, Priya's KV state updates:

```
state.agent.priya.skills = {
  primary: ["terraform", "aws"],
  secondary: ["python (learning, ~6 tasks completed)"],
  goals: ["python proficient by Q3"]
}
```

When Priya feels ready, Maya updates her permissions to add `board.tasks.python.*` — and now Priya is a generalist in two domains. **The permissions evolve with the person.**

**Sam needs help on something tricky.** Sam is doing UI work but hits a backend boundary issue. Sam DMs:

```
nc.request("agents.diego.inbox", 
  { question: "API returns 500 when payload exceeds 1MB — what's the limit?", 
    context: "task T-389" },
  timeout=30s)
```

Diego replies in his inbox handler. Quick chat, no board pollution. If Diego's busy or offline, Sam's request times out, and Sam falls back to posting on `board.tasks.go.pending` with `blocking: T-389` — now it's visible work.

**Daily standup.** Maya broadcasts:

```
publish broadcast.standup
  { time: "10:00", agenda: ["yesterday", "today", "blockers"] }
```

Everyone receives. Each replies on their own `agents.<id>.events` channel:

```
publish agents.lin.events
  { type: "standup_update", yesterday: "...", today: "...", blockers: [] }
```

Maya is subscribed to `agents.*.events` and aggregates. No meeting required — the substrate models the standup as message exchange.

**Incident.** AWS is acting up. Priya broadcasts:

```
publish broadcast.incidents
  { severity: high, system: "staging-vpc", owner: priya, status: investigating }
```

Maya, Raj, everyone gets it. Raj DMs Priya: "Need a hand?" Priya: "yes, can you check the route tables." Direct collaboration, while the broadcast tracks the incident publicly.

## State the team uses

```
state.agent.lin.skills      = { primary: [python, ui], growing: [go] }
state.agent.lin.load        = { current_tasks: 2, capacity: medium }
state.project.user-settings = { owner: lin, blockers: [], status: in_progress }
state.team.alpha.roster     = [maya, raj, lin, sam, diego, priya]
```

Anyone can read these. Permissions on writes vary — agents update their own load, Maya updates project state, skills are updated by Maya after review.

## The validation gateway in this context

Recall the layer-2 gateway. For this team it does specific useful things:

- Rejects a task posted to `board.tasks.terraform.pending` if it's missing `summary` or `priority`
- Rejects a task posted to `board.tasks.go.pending` that says "build a React component" (subject/content mismatch)
- Rejects a learning task posted to `board.learning.python.pending` if it doesn't include `mentor` or `scope_hours` (learning tasks should be bounded)
- Replies to the sender's inbox with what was wrong and a corrected template

For a team of humans this is mostly schema validation. For a team of AI agents, this is what keeps a confused junior agent from posting nonsense — and the structured error teaches it to do better next time.

## Visualizing the team interaction model## Why this design works for a mixed-experience team

A few properties worth naming explicitly:

**Permissions encode the org chart, not just access control.** "Who can claim what" is exactly the same question as "who does what." When Priya levels up in Python, you don't redo the org — you add one line to her permissions. The substrate updates as the team updates.

**Specialists can't accidentally bottleneck delivery.** Because Sam can't claim regular `board.tasks.python.pending`, there's no risk of an under-skilled claim blocking critical work. But Sam is also not gated from learning — the parallel `board.learning.*` tracks make growth a first-class flow with its own rules.

**Mentoring is a posted resource, not a side conversation.** When Raj has bandwidth, he announces it on `board.learning.<domain>.mentoring` and people respond. This makes mentoring visible, schedulable, and fair. Maya can see who's mentoring whom by reading the audit stream.

**Generalists self-route.** Raj subscribes to all `board.tasks.*.pending`. He doesn't need anyone to assign him work; he picks up what's interesting and unblocked. Maya doesn't have to play traffic cop. This is exactly how good senior generalists actually work — they pull, not get pushed.

**Cross-functional pairing is just inboxes.** "I need a UI person to look at this" is `nc.request("agents.sam.inbox", ...)` with a fallback to the board. No meetings, no scheduling, no decision about *which* tool to use for collaboration — the substrate has one.

**The team's history is replayable.** The `audit.>` stream means six months from now Maya can answer "how did we end up with Diego owning the gateway?" by replaying the actual posts. This is impossible with Slack DMs and equally impossible with an org chart.

## What you'd actually build

To make this real for a real team (or a team of agents):

1. **One NATS server or cluster**, one account `team-alpha`.
2. **JetStream streams**: `TASKS` (work-queue retention on `board.tasks.>`), `LEARNING` (work-queue on `board.learning.>`), `RESULTS` (limits retention on `board.results.>`), `AUDIT` (limits retention, mirrors everything).
3. **One KV bucket**: `team-state` for projects, agent load, skills.
4. **Six user credentials**, one per team member, with the permissions sketched above.
5. **One small validation service** (a Python or Go process) sitting between `submit.tasks.>` and `board.tasks.>`, doing schema checks and writing helpful errors.
6. **An agent SDK** — a thin wrapper around the NATS client that knows the conventions: `post_task(domain, payload)`, `claim_task(domain)`, `dm(agent_id, msg)`, `update_status(...)`, `watch(key)`. For human team members this could be a CLI or web UI; for AI agents it's a Python/TypeScript library.
7. **Per-agent permissions reflected in their system prompt** (for AI agents) or their UI (for humans) so the rules are visible up front, not only enforced after a mistake.

Total infrastructure: one NATS deployment, one validation service, one shared library. That's a remarkably small amount of code to model an entire team's coordination — and it scales naturally as the team grows, specializes, or adds AI agents alongside humans.

The deepest property is that **humans and AI agents can be peers in this system**. An AI agent claims a `board.learning.python.pending` task the same way Sam does, with the same permissions discipline, the same validation, the same audit trail. You don't build a separate "AI integration layer" — agents and people share the substrate. That's the payoff of designing the coordination model carefully before you wire anyone in.

## A2A layer (slice 1)

A2A (Agent-to-Agent Protocol) is layered **on top of** the substrate
above — never replaces it. Investigation + decision in
`.tasks/team-alpha-a2a-investigation.md`; first slice in
`.tasks/team-alpha-a2a-impl-slice1.md`.

### What A2A adds

- **Directed dispatch by skill match.** Maya picks a worker via
  `agents/<role>.json` (committed in git, source of truth for skills
  + tier). Continuity bias on `parent_task_id` / `project_id`,
  load-aware fallback. Pull-based `board.tasks.<d>.pending` survives
  for "anyone-can-grab" tasks (slice 2 wires the hybrid).
- **Formal lifecycle.** Single A2A canonical vocabulary used by
  agents:

      submitted → working → input-required → completed
                                          → failed
                                          → canceled

  Substrate states map at the boundary in `a2a/lifecycle.py`. Notably
  preemption (`board.tasks.<d>.parked`) folds to `input-required`
  with `reason: "preempted"` — agents learn one vocabulary.
- **Capability advertisement.** Each role's `agents/<role>.json`
  lists skills + tier (`primary` / `growing`) + auth scheme. Cards
  generated from `acl.py` by `scripts/gen-agent-cards.py` — single
  source of truth, CI-checked drift.

### Subjects

```
a2a.<role>.tasks.send                 dispatch (request-reply)
a2a.<role>.tasks.<task_id>.status     state updates
a2a.<role>.tasks.<task_id>.message    streaming chunks (slice 2+)
a2a.<role>.tasks.<task_id>.cancel     cancel signal (slice 2+)
a2a.discovery.<role>                  card lookup over NATS (slice 2+)
```

### Streams

- `A2A_TASKS` — `a2a.*.tasks.>`, limits retention, 30d.
- `A2A_DISC`  — `a2a.discovery.>`, max-msgs-per-subject 1.
- `AUDIT`     — sources `A2A_TASKS` (replay parity with `board.>`).

### What stays unchanged

- All of MODEL above survives — `board.tasks.>`, `agents.<role>.inbox`,
  `broadcast.>`, KV state, AUDIT replay-as-oracle.
- Test pyramid unchanged; A2A adds smokes (17 in slice 1; 18, 19 in
  slice 2). Existing 1–16 stay green.
- Org-chart-as-permissions still holds; A2A makes capability
  *machine-readable* (cards) instead of only ACL-encoded.

### Dual-write (slice 3)

Existing tools (`claim_task`, `block_task`, `complete_task`,
`park_task`, `resume_task`) publish on `board.tasks.<d>.<state>`
AND mirror the transition to `a2a.<role>.tasks.<task_id>.status`.
Mapping in `a2a/lifecycle.py` (`map_substrate`); bridge in
`a2a/bridge.py`. Task ids deterministic (`a2a:<slug>`) so multiple
ticks bridge to the same A2A task. AUDIT now contains both chains
for every lifecycle event — agents can consume the A2A surface as
canonical without losing substrate backward-compat.

### Trust model (slice 1, MVP)

- Per-role ACL on NATS subjects (`a2a.<role>.tasks.>` per worker,
  `a2a.*.tasks.send` for Maya only). Dispatch bypass is impossible —
  no worker can publish to another role's `tasks.send`.
- Skill match enforced **client-side only** — workers honor their own
  card. A separate bouncer service is not needed: NATS ACL already
  confines dispatch to Maya, and Maya's dispatcher validates skill
  match before sending.

### Card authenticity (slice 2)

Agent cards are stored in KV under `agents.<role>.card` and published
to `A2A_DISC` stream at `a2a.discovery.<role>`. Authenticity is
enforced at the NATS ACL layer:

- Each role's creds allow writes to `$KV.<bucket>.agents.<role>.>`
  only — no role can overwrite a peer's KV subtree.
- `get_peer_cards()` calls `verify_card_acl_scope(role, entry.key)`
  and logs a warning on mismatch. Non-blocking: a mismatch does not
  drop the card, but surfaces the anomaly in server logs.
- External identity verification (JWT NKey fingerprints in card JSON)
  is deferred until the HTTP+SSE bridge (card 169) ships — internal
  trust is fully covered by NATS ACL alone.
