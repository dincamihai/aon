# ai-over-nats — multi-agent collaboration engine over NATS

`ai-over-nats` is a meta-project: an installable engine + CLI that any
team can drop into a private repo to run a multi-human + multi-agent
team over a NATS bus. Each operator stands up their own per-team repo
(`~/Repos/<team>-aon`) holding `aon.toml`, rendered prompts, gitignored
auth. The engine ships templates, scripts, and the `aon` CLI. Inspired
by `ai-fleet-harness`'s init pattern.

> Two audiences in this README:
>
> - **Operators** (humans bringing up a team) — start at §1.
> - **Agents** (claude, joining as a role) — skip to §3.

---

## 1. Operator quickstart (~10 min)

You're standing up a new team. End-state: a NATS substrate, a
per-team repo with roster + auth, and a way for joiners to point a
work-repo at the team.

### 1.1 Prereqs

| Tool | Install |
|---|---|
| `claude` CLI | `npm install -g @anthropic-ai/claude-code` |
| `nats` CLI | `brew install nats-io/nats-tools/nats` |
| `git`, `jq`, `python3`, `openssl` | standard |
| `docker` (or `colima` on macOS) | for the NATS container |

Engine on PATH (pick one):

```bash
# Option A — pipx editable install (recommended)
git clone https://github.com/dincamihai/ai-over-nats ~/Repos/ai-over-nats
pipx install --editable ~/Repos/ai-over-nats
aon help

# Option B — symlink (no Python tooling needed)
git clone https://github.com/dincamihai/ai-over-nats ~/Repos/ai-over-nats
ln -s ~/Repos/ai-over-nats/bin/aon ~/.local/bin/aon
aon help
```

Either way the clone lives on disk — pipx editable points at it, the
symlink references it. Don't `rm -rf` the clone after install.

### 1.2 Create a per-team repo

```bash
mkdir ~/Repos/myteam-aon && cd $_ && git init
aon init                 # writes aon.toml + dir tree
$EDITOR aon.toml         # team name, roster, NATS URLs
```

Roster shape: `[[roles]]` blocks with `name`, `kind ∈
{manager, generalist, specialist}`, `domain`, optional
`learning`. See `templates/aon.toml.example` for a 6-role
reference.

### 1.3 Render prompts + auth

```bash
aon prompts render       # → agent-prompts/<role>.md (one per role + _common.md)
aon auth render          # → nats/auth.conf.example
aon auth set-passwords   # → nats/auth.conf + nats/.passwords (chmod 600)
```

Re-runnable. Idempotent. Hand-edit the rendered files for per-team
nuance — the renderer overwrites, but per-role tweaks usually live
on top of the templates and are re-applied as you iterate.

### 1.4 Bring up NATS + bootstrap

```bash
# NATS via the engine's docker-compose, mounting your auth.conf
docker compose -f $(realpath ~/Repos/ai-over-nats)/docker-compose.yml \
  --project-name $(basename $PWD) up -d nats

aon bootstrap            # streams + KV from aon.toml roster
aon doctor               # green ✓
```

### 1.5 Push the team repo + invite joiners

```bash
git add -A && git commit -m "init team"
gh repo create dincamihai/myteam-aon --private --source=. --push
gh repo edit dincamihai/myteam-aon --add-collaborator <gh-username>
```

Out-of-band (1Password / private DM — never plain chat):

- repo URL
- assigned role
- role password (from `nats/.passwords`)
- NATS URL (loopback, Tailscale IP, or `wss://nats.<domain>` via cloudflared)

### 1.6 (Optional) cloudflared tunnel for remote joiners

If joiners are off-LAN, expose NATS over a Cloudflare tunnel:

```bash
cloudflared tunnel login
cloudflared tunnel create myteam-nats
cloudflared tunnel route dns myteam-nats nats.<your-domain>
# ~/.cloudflared/config.yml: ingress nats.<your-domain> → http://localhost:8080
cloudflared tunnel run myteam-nats
```

Joiners use `wss://nats.<your-domain>`.

### 1.7 (Optional) Sandbox the team in a colima VM

For VM-level isolation per worker (AppArmor + DAC + systemd
hardening) see `docs/sandbox.md` and `bin/team-alpha-apparmor`.

---

## 2. Joiner quickstart (~5 min)

You received: role, role password, NATS URL, repo URL.

```bash
# one-time engine install (operator probably already did this on the
# joiner's behalf when distributing setup instructions)
git clone https://github.com/dincamihai/ai-over-nats ~/Repos/ai-over-nats
pipx install --editable ~/Repos/ai-over-nats

# per-team join
git clone <team-repo-url> ~/Repos/<team>-aon
cd ~/Repos/<team>-aon
aon join <role> <work-repo>
# interactive prompts: password (skipped if .passwords exists), NATS URL
cd <work-repo> && claude
```

`aon join` saves creds to `~/.team-alpha/<role>.password` (chmod 600),
stamps `.claude/settings.json` + `.mcp.json` into `<work-repo>`,
verifies a NATS handshake, symlinks `<work-repo>/CLAUDE.md` to your
role brief, and prints the launch line.

`scripts/join.sh` is a shim that forwards to `aon join`; existing
instructions remain valid for one release.

---

## 3. Agent first-turn (when claude boots in `<work-repo>`)

You are a worker agent. Read this once.

### 3.1 What you should already have

Your human ran `bash scripts/join.sh <role> <work-repo>` before
launching you. That script:

- saved the role password to `~/.team-alpha/<role>.password` (chmod 600)
- stamped `.claude/settings.json` + `.mcp.json` into `<work-repo>`
- verified a NATS handshake as your role

If those files aren't present, stop and tell the human to run
`join.sh` first.

### 3.2 First-turn sequence

1. **Resolve identity.**
   - `$TEAM_ALPHA_ROLE` = your role.
   - `$TEAM_ALPHA_NATS_URL` = bus URL.
   - `$TEAM_ALPHA_CREDS` = path to your password file.
   - Read `agent-prompts/_common.md` and `agent-prompts/<role>.md`.
2. **SessionStart hooks** run automatically: subscribe Monitors,
   emit `agents.<role>.events {kind:"hello"}`, inject queued events.
3. **Read MCP tools** — `mcp__team-alpha__*`, `mcp__team-alpha-board__*`.
4. **Run the cycle loop** (full description in `_common.md`):
   catch up → check policy + human-availability KV → claim
   work → emit progress → ship → end-of-cycle summary.

### 3.3 House rules

- **Identity.** You are the role. No spawning peers.
  `Permissions Violation` is signal, not flake.
- **Audit.** All publishes mirror into `AUDIT` automatically.
  Don't write a separate log file.
- **Git workflow.** Always feature branch + PR. Direct push to
  main is blocked by convention (see `.github/CODEOWNERS`).
- **ASK discipline.** DM peer once → DM coord once → publish
  `state.alert.no_human` once → STOP. Never guess.
- **Retry discipline.** (a) substrate-transient = backoff +
  reconnect. (b) policy-deny / contract-violation = report,
  don't retry.
- **Preemption.** On `preempts: <slug>`: commit `wip`, push to KV
  parked stack, claim new task. LIFO-pop on done.
- **Resume-prompt hijack** (defect 216): first turn may show a
  global "pending resume prompts" block. Ignore.

### 3.4 When in doubt

| Question | Read |
|---|---|
| Substrate, identity, retry, ASK | `agent-prompts/_common.md` |
| Your scope / peers / domain | `agent-prompts/<your-role>.md` |
| Subject taxonomy + KV layout | `MODEL.md` + `_common.md` |
| Multi-human bring-up | `docs/team-session-runbook.md` |
| VM sandbox / AppArmor | `docs/sandbox.md` |
| `aon` CLI reference | `aon help` |

### 3.5 You do NOT need to

- Install anything. Your human did it.
- Hold credentials in chat. They live at
  `~/.team-alpha/<role>.password`.
- Maintain a parallel log. Substrate publishes ARE the log.
- Run `aon bootstrap` / `cloudflared` / `docker compose` —
  operator paths.

---

## 4. `aon` CLI subcommand reference

```
aon init                       bootstrap harness in current repo
aon add-role NAME KIND DOMAIN  append role to aon.toml roster
aon doctor                     sanity-check local setup
aon prompts render             render agent-prompts/<role>.md
aon auth render                render nats/auth.conf.example
aon auth set-passwords         substitute PASSWORD_* → nats/auth.conf
aon bootstrap                  ensure streams + KV from roster
aon hmac genkey|status|mode    payload signing key + mode
aon apparmor SUB               personal AppArmor overrides (sync|show|reload|watch)
```

Full source: `~/Repos/ai-over-nats/bin/aon`. Schema reference:
`~/Repos/ai-over-nats/templates/aon.toml.example`.

---

## 4a. Payload signing (HMAC)

Tamper-evident payloads via HMAC-SHA256 envelopes keyed by a shared
cluster secret. Threat model: relay/operator tampering of stored or
forwarded messages, replay of AUDIT events. (Per-role identity proof
needs Ed25519 post-JWT; out of scope.)

Modes (`TEAM_ALPHA_HMAC_MODE`):

- `off` (default) — no signing, no verification.
- `warn`  — sign on publish; verify if signed; accept unsigned + log.
- `strict` — sign on publish; reject unsigned/bad-sig/stale/replayed.

Operator rollout:

```
aon hmac genkey                 # ~/.team-alpha/cluster.hmac (chmod 600)
# distribute identical file out-of-band to every role's host
aon hmac mode warn              # all hosts; restart roles; soak ≥48h
aon hmac mode strict            # all hosts; restart roles
```

`aon launch` / `aon monitor` / `aon join` export
`TEAM_ALPHA_HMAC_KEY_FILE` + `TEAM_ALPHA_HMAC_MODE` automatically and
bake them into `.mcp.json` + hooks env-prefix.

Full runbook (rollout, rotation, troubleshooting): `docs/hmac-runbook.md`.

---

## 5. Layout

```
ai-over-nats/                                 ← engine
  bin/aon                                     ← CLI entrypoint
  bin/_aon-lib.sh                             ← TOML parser + helpers
  bin/team-alpha-apparmor                     ← sandbox helper
  bin/team-alpha-doctor                       ← sandbox doctor
  templates/aon.toml.example                  ← schema reference
  templates/agent-prompts/*.md.tmpl           ← per-kind prompt templates
  templates/auth/*.tmpl                       ← per-kind ACL blocks
  scripts/                                    ← bootstrap, join, hooks, sandbox
  mcp-server/                                 ← team-alpha-mcp Python pkg
  schemas/                                    ← event + card JSON schema
  docs/                                       ← engine docs (sandbox, runbook)
  docker-compose.yml                          ← NATS for any team
```

Per-team repo (operator-managed):

```
<team>-aon/
  aon.toml                                    ← roster + paths + NATS URLs
  agents/<role>.json                          ← agent cards
  agent-prompts/{_common,<role>}.md           ← rendered briefs
  nats/auth.conf                              ← gitignored, generated
  nats/auth.conf.example                      ← rendered, committed
  nats/.passwords                             ← gitignored, chmod 600
  .tasks/                                     ← team's task cards
  docs/                                       ← team-specific runbooks
```

---

## License

Internal. Not yet public.
