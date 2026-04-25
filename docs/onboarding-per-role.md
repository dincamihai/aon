# team-alpha — per-role machine setup

What each team member does once on their machine to get their Claude agent
talking to the substrate. Six roles, common base, role-specific monitors.

See [MODEL.md](../MODEL.md) for the why; this doc is the how.

> **Before any of this works, someone has to host the substrate.** That is a
> separate role — the operator — covered in §0. The six team roles in §1–§2
> are users of a substrate that already exists. If no one is the operator,
> nothing in §1+ works.

---

## 0. Operator — host the substrate (one person, before everyone else)

The operator stands up and maintains the NATS server itself. **This is not
one of the six team roles** (Maya, Raj, Lin, Sam, Diego, Priya). It's the
human (or small group) who owns the infra. Common patterns:

- **Small team**: someone wears the ops hat alongside their regular role.
  Often the manager (Maya) or the infra specialist (Priya). Make the choice
  explicit — record who in `docs/operator.md` so the team knows where to
  page.
- **Larger org**: a dedicated platform / SRE person outside the 6. Treat
  team-alpha's NATS like any other shared service.
- **Solo POC**: whoever is iterating on the design. You.

The operator holds the **`sysadmin`** credential (`>` permissions, stream and
KV admin). This password is **never** distributed to the six team members —
they don't need it, and giving it out collapses the permission model.

### 0.1. One-time setup

1. **Pick a host** reachable by the team:
   - Local POC: a laptop on the same network.
   - Real deploy: a small VM on the company VPN.
2. **Install Docker + Docker Compose**.
3. **Clone substrate repo** to the host:
   ```bash
   git clone <ai-over-nats-repo-url> ~/Repos/ai-over-nats
   cd ~/Repos/ai-over-nats
   ```
4. **Generate per-user passwords** (one each for sysadmin + 6 roles + sys):
   ```bash
   cp nats/auth.conf.example nats/auth.conf
   for who in SYSADMIN MAYA RAJ LIN SAM DIEGO PRIYA SYS; do
     pw=$(openssl rand -hex 24)
     # macOS sed:
     sed -i '' "s/PASSWORD_$who/$pw/" nats/auth.conf
     echo "$who=$pw"
   done > /tmp/team-alpha-passwords.txt   # capture for distribution
   chmod 600 /tmp/team-alpha-passwords.txt
   ```
   `nats/auth.conf` is gitignored. Distribute each user's password via
   the company secret manager (1Password, Bitwarden, …). **Never paste in
   chat, email, or git.** Delete `/tmp/team-alpha-passwords.txt` after
   distribution.
5. **Start NATS**:
   ```bash
   export TEAM_ALPHA_SERVER_NAME=team-alpha-1
   docker compose up -d nats
   curl -s http://127.0.0.1:8222/healthz       # expect {"status":"ok"}
   ```
6. **Bootstrap streams + KV** (card 30, once that lands):
   ```bash
   export NATS_URL=nats://localhost:4222
   export NATS_ADMIN_USER=sysadmin
   export NATS_ADMIN_PASSWORD=<from secret manager>
   bash scripts/bootstrap.sh
   ```
   Idempotent. Re-run after upgrades. Creates `TASKS`, `LEARNING`, `RESULTS`,
   `AUDIT` streams + `team-state` KV bucket + seed values.
7. **Network the host** so team members reach it (see [network.md](network.md)
   once card 70 lands — bind to corp VPN iface, register internal DNS name
   `nats.team-alpha.corp`).

### 0.2. Ongoing ops

- **Add a new team member**: edit `nats/auth.conf` adding a `users:` entry
  with appropriate ACL (mirror an existing role w/ similar level), generate
  password, distribute, `docker compose restart nats` (zero data loss; KV +
  streams persist on volume `nats_data`).
- **Promote a role** (e.g. Priya graduates to Python production work): edit
  her permission block in `nats/auth.conf` adding
  `board.tasks.python.{claimed,blocked,done}` and `board.results.python.>`,
  restart nats. Permissions evolve with the person — see §5.
- **Rotate a password**: regenerate, update `nats/auth.conf`, restart nats,
  redistribute via secret manager. Old password stops working immediately on
  restart.
- **Backup**: snapshot the `nats_data` Docker volume nightly. Restore =
  recreate volume from snapshot, `docker compose up -d`. Streams + KV
  intact.
- **Monitor**: HTTP `:8222/jsz` for stream stats, `:8222/varz` for server
  state, `:8222/healthz` for liveness probe.

### 0.3. What the operator does NOT do

- Not a Claude agent. No `TEAM_ALPHA_ROLE` env, no `claude` session against
  the substrate as `sysadmin`. The operator's interaction is shell + docker
  + occasional `nats` CLI runs.
- Doesn't post tasks, claim work, or participate on the boards. Even if
  Maya is also operator, she has two hats: the ops hat (sysadmin creds) and
  the manager hat (maya creds + Claude agent). Keep them separate.

---

## 1. Common — every member

### 1.1. Install nats CLI

```bash
brew install nats-io/nats-tools/nats          # macOS
# or
go install github.com/nats-io/natscli/nats@latest
```

Verify:

```bash
nats --version
```

### 1.2. Get on the network

Substrate binds the company VPN interface (see
[network.md](network.md) once it lands). Connect to corp VPN, then:

```bash
ping nats.team-alpha.corp
```

Off-VPN this must fail. On-VPN it must resolve.

### 1.3. Receive password

Team admin distributes via the company secret manager (1Password, Bitwarden,
etc). **Never paste in chat, never commit, never email.**

Save locally:

```bash
mkdir -p ~/.team-alpha && chmod 700 ~/.team-alpha
printf '%s' '<paste-password>' > ~/.team-alpha/<role>.password
chmod 600 ~/.team-alpha/<role>.password
```

Replace `<role>` with one of: `maya`, `raj`, `lin`, `sam`, `diego`, `priya`.

### 1.4. Set environment

Append to `~/.zshrc` or `~/.bashrc`:

```bash
export TEAM_ALPHA_ROLE=<your-role>
export TEAM_ALPHA_NATS_URL=nats://nats.team-alpha.corp:4222
export TEAM_ALPHA_CREDS=$HOME/.team-alpha/$TEAM_ALPHA_ROLE.password
```

Open new shell. Verify: `echo $TEAM_ALPHA_ROLE`.

### 1.5. Clone substrate repo

```bash
git clone <ai-over-nats-repo-url> ~/Repos/ai-over-nats
cd ~/Repos/ai-over-nats
```

Repo holds role prompts, hooks, onboard script.

### 1.6. Install hooks

```bash
bash scripts/hooks/install.sh
```

Wires `session-start-catch-up.sh` and `stop.sh` into project-level
`.claude/settings.json`. Idempotent.

### 1.7. Smoke connect

```bash
nats --server "$TEAM_ALPHA_NATS_URL" \
     --user "$TEAM_ALPHA_ROLE" \
     --password "$(cat $TEAM_ALPHA_CREDS)" \
     server check connection
```

Expect `OK Connection`. If `nats: timeout` → not on VPN. If `Authorization
Violation` → wrong password.

### 1.8. Launch Claude

```bash
cd ~/Repos/ai-over-nats && claude
```

First turn:

```
bash scripts/onboard.sh $TEAM_ALPHA_ROLE
```

Onboard script: validates env, posts handshake to `agents.<role>.events`,
prints role prompt, prints monitor commands to start.

### 1.9. Start persistent Monitors

In the Claude session, start the monitors listed in §2 below for your role.
Each `nats sub` runs in background; new messages arrive as notifications the
agent reacts to.

---

## 2. Role-specific monitors + behavior

Each subsection: what to subscribe to, what publishing is allowed, what's
forbidden, what to do day-to-day.

### 2.1. Maya — manager

**Subscribe**

```bash
nats sub agents.maya.inbox     # DMs
nats sub 'agents.*.events'     # presence + per-agent activity
nats sub 'broadcast.>'         # incidents, standup
nats sub 'state.>'             # KV reflection (optional, situational)
```

**Allowed publish**

- `broadcast.>` — announcements
- `board.tasks.*.pending` — post work in any domain
- `board.tasks.review.>` — request reviews
- `state.project.>` — project status
- `agents.*.inbox` — DM anyone
- `agents.maya.events` — own activity

**Forbidden** (server rejects)

- `board.results.>` — doers post results, not manager

**Day-to-day**

- Post tasks: `nats pub board.tasks.terraform.pending '{"summary":"...","priority":"medium"}'`
- Standup: `nats pub broadcast.standup '{"time":"10:00","agenda":[...]}'`
- Update project state: `nats kv put team-state project.<id> '{"status":"...","owner":"..."}'`

---

### 2.2. Raj — senior generalist

**Subscribe**

```bash
nats sub agents.raj.inbox
nats sub 'board.tasks.*.pending'         # all domains — pull what fits
nats sub 'board.learning.*.pending'      # learning queue
nats sub 'board.learning.*.mentoring'    # see other mentors
nats sub 'broadcast.>'
```

**Allowed publish**

- `board.tasks.*.{claimed,blocked,done}` — claim/work in any domain
- `board.results.>` — post results in any domain
- `board.learning.*.mentoring` — offer mentoring
- `agents.*.inbox`

**Day-to-day**

- Self-route: pick the most useful pending task; claim with
  `nats pub board.tasks.<domain>.claimed '{"task_id":"...","by":"raj"}'`.
- Offer mentoring:
  `nats pub board.learning.go.mentoring '{"mentor":"raj","hours":4,"topics":["concurrency"]}'`.
- DM specialists for fast pair-ups.

---

### 2.3. Lin — mid generalist, learning Go

**Subscribe**

```bash
nats sub agents.lin.inbox
nats sub 'board.tasks.python.pending'
nats sub 'board.tasks.ui.pending'
nats sub 'board.tasks.go.pending'
nats sub 'board.learning.go.>'           # growth track
nats sub 'broadcast.>'
```

**Allowed publish**

- `board.tasks.{python,ui,go}.{claimed,blocked,done}`
- `board.results.{python,ui,go}.>`
- `board.learning.go.claimed`
- `agents.*.inbox`

**Forbidden**

- Other domains (`terraform`, `aws`) — out of scope.

**Day-to-day**

- Claim python/ui solo.
- For Go regular work: claim, AND DM Raj or Diego for pairing.
- Go learning: freely claim `board.learning.go.pending`.

---

### 2.4. Sam — UI specialist, growing into backend

**Subscribe**

```bash
nats sub agents.sam.inbox
nats sub 'board.tasks.ui.pending'              # main work
nats sub 'board.learning.python.pending'       # stretch
nats sub 'board.learning.go.pending'
nats sub 'board.learning.python.mentoring'     # find mentors
nats sub 'board.learning.go.mentoring'
nats sub 'broadcast.>'
```

**Allowed publish**

- `board.tasks.ui.{claimed,blocked,done}`
- `board.results.ui.>`
- `board.learning.{python,go}.claimed`
- `agents.*.inbox`

**Forbidden** (server rejects)

- `board.tasks.python.pending` claim — production python work goes to
  generalists.
- `board.tasks.go.pending` claim — same.
- Use `board.learning.python.pending` / `board.learning.go.pending` instead
  (mentor-paired, scoped, not on critical path).

**Day-to-day**

- Default work: UI tasks.
- Backend growth: watch `board.learning.{python,go}.mentoring`, DM mentor when
  one announces, claim a learning task they post.

---

### 2.5. Diego — Go specialist, growing into infra

**Subscribe**

```bash
nats sub agents.diego.inbox
nats sub 'board.tasks.go.pending'              # main work
nats sub 'board.learning.terraform.>'          # stretch
nats sub 'board.learning.aws.>'
nats sub 'broadcast.>'
```

**Allowed publish**

- `board.tasks.go.{claimed,blocked,done}`
- `board.results.go.>`
- `board.learning.{terraform,aws}.claimed`
- `agents.*.inbox`

**Forbidden**

- `board.tasks.{terraform,aws}.pending` claim — go through learning.

**Day-to-day**

- Default: Go tasks.
- Infra growth: watch learning channels, claim mentor-posted infra learning
  tasks, pair with Priya/Raj.

---

### 2.6. Priya — Terraform/AWS specialist, learning Python

**Subscribe**

```bash
nats sub agents.priya.inbox
nats sub 'board.tasks.terraform.pending'
nats sub 'board.tasks.aws.pending'
nats sub 'board.learning.python.>'
nats sub 'broadcast.>'
```

**Allowed publish**

- `board.tasks.{terraform,aws}.{claimed,blocked,done}`
- `board.results.{terraform,aws}.>`
- `board.learning.python.claimed`
- `agents.*.inbox`

**Forbidden**

- `board.tasks.python.pending` claim.

**Day-to-day**

- Default: Terraform/AWS work.
- Python growth: pair-claim learning tasks with Lin or Raj.

---

## 3. What "the Claude agent does X" means concretely

Inside a Claude Code session, the agent doesn't manually re-run those `nats
sub` commands each turn. Two mechanisms keep it reactive:

### 3.1. Persistent Monitors (in-session)

Use the Claude Code `Monitor` tool to start each `nats sub` command in
background. Each new published message = system notification → the agent
reads it without polling.

Suggested monitors per role: see §2 above.

### 3.2. Hooks (cross-session)

- `session-start-catch-up.sh` — at session start, replays last 50 events
  since the last cursor (kept at `~/.team-alpha/last-seen-<role>`) and injects
  them as `additionalContext`. Catches up after long offline.
- `stop.sh` — at session end, flips `state.agent.<role>.load = idle` in KV
  and emits `agents.<role>.events session_end`.

Hooks live in `scripts/hooks/`, wired by `bash scripts/hooks/install.sh`.

### 3.3. Role prompt

`scripts/agent-prompts/<role>.md` is loaded as system context. Tells the
agent:

- which subjects it can publish/subscribe (matches ACL exactly)
- claim policy (first-claim-wins on JetStream work-queue)
- ASK discipline — when stuck, DM a specialist or post `.blocked`
- end-of-cycle output format

The agent reasons *with* the substrate, not separate from it.

---

## 4. Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `nats: timeout` on connect | not on VPN | reconnect VPN, retry `ping nats.team-alpha.corp` |
| `Authorization Violation` | wrong/missing password | re-fetch from secret manager, check `chmod 600` |
| `Permissions Violation for Publish to ...` | ACL working as intended | re-read your role's allowed subjects in §2; you're trying to publish outside scope |
| Monitor never fires | wrong subject pattern | check brace expansion isn't shell-eaten — use single quotes around `'board.tasks.*.pending'` |
| `session-start-catch-up.sh` injects nothing | cursor file missing or fresh install | normal first time; second run will populate |

---

## 5. Permissions evolve with the person

Permissions in `nats/auth.conf` are not fixed forever. When someone levels up
in a domain (e.g. Priya hits Python proficiency after N learning tasks),
team admin adds the production subjects to that user's allow list and
redeploys the conf. The substrate matches the team's actual capabilities,
not yesterday's snapshot.

This is the deeper point of MODEL.md §"Permissions encode the org chart" —
edit one ACL entry, the team's coordination surface updates immediately.
