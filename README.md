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

### 1.5 Onboard a joiner — recommended one-shot

```bash
aon onboard <name>                                      # defaults: generalist / fullstack
aon onboard <name> specialist <skill>
```

`aon onboard` reads the NATS URL from `aon.toml [nats] url` (or the
`AON_NATS_URL` env). To rotate the tunnel, edit `aon.toml` (or run
`aon set-nats-url <bits>` for the joiner-side env files), then run
`aon doctor` to verify before onboarding. Bits travel out-of-band
only — they must NEVER live in `aon.toml`'s committed `ws_url`.

Composes 7 steps idempotently: roster + render + auth + creds + NATS
up + commit/push + token emit. ~30s on a warm operator box.
Failure-safe — any step's failure aborts with a clear hint. Env
health is verified separately by `aon doctor` (single source of
truth — no duplicate inline probe).

Output is a **single curl command** (token + bits embedded). Send it
to the joiner via 1Password share / private DM (never plain chat —
token contains the password). Joiner pastes it. ~3 min to `claude`
boot, no engine clone, no pipx install required.

When cloudflared restarts and your bits change, just DM joiners the
new bits — they run `aon set-nats-url <new-bits>` (or curl the same
join-link script with the new bits as arg 2). No re-onboard.

For granular control or non-typical flows, use the per-step commands
in §1.5.x:

#### 1.5.x (advanced) granular operator flow

If `aon onboard` doesn't fit your case, run the underlying steps:

```bash
aon creds --all          # writes ~/.aon/teams/<team>/creds/<role>.password (chmod 600) for every role
# or: aon creds <role> [DEST]   for a single role
```

The password file is what every joiner needs locally. `aon launch`,
`aon monitor`, and `aon join` all read from it. The shared
`nats/.passwords` is the operator-side source; per-role files are the
distributable artifact.

### 1.6 Push the team repo + invite joiners

```bash
git add -A && git commit -m "init team"
gh repo create dincamihai/myteam-aon --private --source=. --push
gh repo edit dincamihai/myteam-aon --add-collaborator <gh-username>
```

Out-of-band (1Password / private DM — never plain chat):

- repo URL
- assigned role
- role password (`~/.aon/teams/<team>/creds/<role>.password` from §1.5)
- NATS URL (loopback, Tailscale IP, or `wss://nats.<domain>` via cloudflared)

### 1.7 (Optional) cloudflared tunnel for remote joiners

If joiners are off-LAN, expose NATS over a Cloudflare tunnel:

```bash
cloudflared tunnel login
cloudflared tunnel create myteam-nats
cloudflared tunnel route dns myteam-nats nats.<your-domain>
# ~/.cloudflared/config.yml: ingress nats.<your-domain> → http://localhost:8080
cloudflared tunnel run myteam-nats
```

Joiners use `wss://nats.<your-domain>`.

### 1.8 (Optional) Sandbox the team in a colima VM

For VM-level isolation per worker (AppArmor + DAC + systemd
hardening) see `docs/sandbox.md` and `bin/team-alpha-apparmor`.

---

## 2. Joiner quickstart — 2 commands (~3 min)

The operator's `aon onboard` output gave you 2 commands. Paste them.
That's the entire setup.

```bash
gh repo clone dincamihai/ai-over-nats ~/Repos/ai-over-nats
~/Repos/ai-over-nats/bin/aon join-link aon://<token> <cloudflared-bits>
```

Prereq: `gh auth login` already done + read access to the engine repo.

Then:

```bash
cd <work-repo> && claude
```

What happens under the hood:

1. Clones the team-aon repo into `~/.aon/teams/<team>/repo/` (or
   symlinks it if you ran from inside a matching checkout).
2. Writes creds to `~/.aon/teams/<team>/creds/<role>.{password,env}`
   (chmod 600).
3. Probes the NATS handshake.
4. Registers `(<work-repo>, team, role)` in `~/.aon/work-repos.json`.
5. Installs MCP servers into `<work-repo>/.mcp.json` (per-repo,
   gitignored) and hook commands into `<work-repo>/.claude/settings.json`
   (per-repo, COMMITTED — joiners get hooks for free on `git pull`).
   Hook commands use the portable `aon hook <name>` launcher — engine
   dir resolves at runtime via `aon` on PATH; no operator-absolute
   paths baked in. `aon doctor` re-verifies portability on every run
   (warns on operator-added commands, fails on absolute paths).
6. Writes a CLAUDE.md aon block in `<work-repo>` telling claude to
   call `get_role_brief()` on first turn.

**Hooks no longer live in `~/.claude/settings.json`.** Sessions opened
in unrelated repos don't fire team hooks (no fork+exec cost, no
side-effect risk, no surprise scripts running outside the work-repo).
Re-running `aon join` migrates any legacy global team hooks out
automatically.

Add `aon` to PATH for rotation later:

```bash
export PATH="$HOME/Repos/ai-over-nats/bin:$PATH"
```

### Tunnel rotated? Run `aon set-nats-url <new-bits>`

When the operator DMs you new cloudflared bits, you DON'T re-onboard.

```bash
aon set-nats-url <new-cloudflared-bits>
# restart claude in your work-repo
```

By default rotates **every role registered in the team** on this host
(tunnel URL is team-scoped). Use `--role NAME` for a single role.

Updates `~/.aon/teams/<team>/creds/<role>.env` only — no per-repo file
edits, since nothing is stamped per repo. MCP server picks up the new
URL on next startup.

> **`$ANTHROPIC_API_KEY` warning is harmless.** Claude subscription
> users (Code / Pro / Max) `/login` inside `claude` on first run.

### 2.0 (advanced) granular joiner flow

If you don't have a token (or want manual control):

```bash
git clone <team-repo-url> ~/Repos/<team>-aon
cd ~/Repos/<team>-aon
aon join <role> /absolute/path/to/<work-repo>
# enter password when prompted; at NATS URL prompt use wss:// (not https://)
cd <work-repo> && claude
```

`aon join` writes creds to `~/.aon/teams/<team>/creds/`, registers the
work-repo, installs the global MCP+hooks, probes NATS, and prints the
launch line.

### 2.1 Operator-side observability during a trial

While a joiner is running, the operator gets live visibility with:

```bash
aon monitor <role>          # tails agents.<role>.events + inbox + their boards
# or, in a fresh shell already exporting TEAM_ALPHA_ROLE:
aon monitor                 # role defaults from env
```

Run one pane per role you want to watch (joiner role, coordinator,
mentor). The monitor pulls NATS URL + creds from the team's
`aon.toml` + `~/.aon/teams/<team>/creds/<role>.password` automatically — no
manual env setup.

---

## 2.5 Trial-test runbook (operator + one joiner, ~10 min)

Use this for adding a new joiner mid-cycle (e.g. trying a generalist
role on an existing team) without re-bootstrapping the whole substrate.

**Operator side** (in the per-team repo):

```bash
# 1. Add the role to the roster if it's new
aon add-role <name> generalist <domain>     # e.g. aon add-role vahid generalist python

# 2. Re-render prompts + auth so the new role gets a brief + ACL block
aon prompts render
aon auth render
aon auth set-passwords        # idempotent: only fills new placeholders

# 3. Materialize the role's local creds file
aon creds <name>              # → ~/.aon/teams/<team>/creds/<name>.password (chmod 600)

# 4. (If NATS is already up) reload auth so the new user is recognised
aon nats up                   # restart nats container with new auth.conf

# 5. Verify the role can connect with its password
aon doctor
```

Out-of-band to the joiner: role name, role password (cat
`~/.aon/teams/<team>/creds/<name>.password`), team repo URL, NATS URL.

**Joiner side**:

```bash
git clone <team-repo-url> ~/Repos/<team>-aon
cd ~/Repos/<team>-aon
aon join <name> <work-repo>
cd <work-repo> && claude
```

**Operator monitors** (separate panes):

```bash
aon monitor <name>            # joiner's traffic
aon monitor maya              # coordinator (or whatever your manager role is)
```

End-of-trial cleanup:

```bash
# Joiner
rm ~/.aon/teams/<team>/creds/<name>.password

# Operator (only if dropping the role permanently)
$EDITOR aon.toml              # remove the [[roles]] block
aon prompts render && aon auth render && aon auth set-passwords
aon nats up                   # reload
```

---

## 3. Agent first-turn (when claude boots in `<work-repo>`)

You are a worker agent. Read this once.

### 3.1 What you should already have

Your human ran `aon join-link <token> <bits>` (or `aon join <role>
<work-repo>`) before launching you. That command:

- saved the role password to `~/.aon/teams/<team>/creds/<role>.password` (chmod 600)
- registered `(<work-repo>, team, role)` in `~/.aon/work-repos.json`
- installed MCP server in `<work-repo>/.mcp.json` (gitignored) + hooks in `<work-repo>/.claude/settings.json` (COMMITTED — portable via `aon hook`)
- verified a NATS handshake as your role

The MCP server resolves your role from cwd at startup. On your first
turn, call `get_role_brief()` to load your role-specific operating
context. If the MCP server isn't connected, tell the human to run
`aon doctor` and `aon join` from this work-repo.

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
  `~/.aon/teams/<team>/creds/<role>.password`.
- Maintain a parallel log. Substrate publishes ARE the log.
- Run `aon bootstrap` / `cloudflared` / `docker compose` —
  operator paths.

---

## 4. `aon` CLI subcommand reference

```
aon init                       bootstrap harness in current repo
aon onboard NAME [KIND] [DOMAIN]  one-shot operator onboarding (recommended)
                               reads NATS URL from aon.toml [nats] url —
                               run `aon doctor` first if you're not sure
                               the env is healthy. composes add-role +
                               render + auth + creds + nats up +
                               commit/push + token emit.
                               defaults: KIND=generalist, DOMAIN=fullstack
aon add-role NAME [KIND] [DOMAIN]  append role to aon.toml roster
                               defaults: KIND=generalist, DOMAIN=fullstack
aon doctor                     sanity-check local setup
aon prompts render             render agent-prompts/<role>.md from templates
aon auth render                render nats/auth.conf.example from roster
aon auth set-passwords         substitute PASSWORD_* → nats/auth.conf + nats/.passwords
aon bootstrap                  ensure JetStream streams + KV from roster
aon nats SUB                   docker compose wrapper (up|down|logs|status)
aon creds ROLE [DEST]          write per-role password file (chmod 600)
aon creds --all                write every per-role password file at once
aon launch ROLE [WORK_REPO]    set env, install hooks, exec claude as ROLE
aon join ROLE WORK_REPO        full joiner setup (creds, registry write,
                               global MCP + hooks install, NATS handshake)
aon join-link TOKEN BITS       one-shot joiner setup from operator's token + bits
                               (recommended) — clones team repo into the registry,
                               places creds, runs aon join. Re-run with new BITS
                               to rotate NATS URL only (no re-clone).
aon set-nats-url BITS          tunnel rotation. By default rotates every role in
                               the team on this host; --role NAME for surgical.
aon resolve-env [--strict]     echo shell `export` lines from cwd → registry
                               (used by hooks; silent on miss without --strict)
aon monitor [ROLE]             tail role's NATS subjects in a separate pane.
                               Resolves role + URL + creds from cwd registry;
                               falls back to operator-side aon.toml + arg/$TEAM_ALPHA_ROLE.
aon apparmor SUB               personal AppArmor overrides (sync|show|reload|watch)
```

### Env-overrides-config

Pre-set environment variables win over `aon.toml` for these vars:

```
AON_TEAM_DIR     AON_TEAM_NAME    AON_TEAM_ACCOUNT  AON_TEAM_KV
AON_NATS_URL     AON_NATS_WS_URL  AON_NATS_ADMIN
```

Unset env → value resolves from `aon.toml`. Empty-string env (`export
AON_NATS_URL=""`) is treated as unset (`${VAR:-default}` semantic) and
also falls through to the toml value. To force an explicit empty,
edit `aon.toml`.

Full source: `~/Repos/ai-over-nats/bin/aon`. Schema reference:
`~/Repos/ai-over-nats/templates/aon.toml.example`.

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
  scripts/nsc-smoke/run-smoke.sh              ← NSC pipeline e2e (CI gate)
  scripts/aon-tests/*.sh                      ← engine unit-style tests
                                                (auto-discovered by
                                                 `_run-all.sh`; runs in CI)
  mcp-server/                                 ← team-alpha-mcp Python pkg
  schemas/                                    ← event + card JSON schema
  docs/                                       ← engine docs (sandbox, runbook)
  docker-compose.yml                          ← NATS for any team
```

Engine tests live in two suites that stay separate:

- `scripts/nsc-smoke/run-smoke.sh` — full NSC + nats-server pipeline,
  ~10min, runs containers. Don't add new unit-style cases here.
- `scripts/aon-tests/*.sh` — fast, self-contained unit-style checks
  (currently `git-guard.sh`). Add new tests by dropping a `chmod +x`
  script in this dir; `_run-all.sh` auto-discovers and runs them in
  CI. Each script handles its own setup/teardown and prints PASS/FAIL
  per case. Local: `bash scripts/aon-tests/_run-all.sh`.

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
