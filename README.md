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

**macOS ARM (Apple Silicon)** — use colima with the vz driver:

```bash
brew install colima docker
colima start --arch aarch64 --vm-type vz --name colima-arm
docker context use colima-arm
```

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

**`pynacl` (needed by `aon connect`)** — auto-bootstrapped on first
run: creates `$AON_ENGINE_DIR/.venv` and `pip install pynacl` into it
automatically. No manual step needed on a machine with outbound pip
access.

Air-gapped / pip-blocked fallback:

```bash
python3 -m venv ~/Repos/ai-over-nats/.venv
~/Repos/ai-over-nats/.venv/bin/pip install --no-index \
  --find-links /path/to/wheels pynacl
```

Verify: `aon doctor` reports `✓ engine venv has pynacl` (or warns with
the exact fix command if the venv exists but the import fails).

### 1.2 Create a per-team repo

```bash
mkdir ~/Repos/myteam-aon && cd $_ && git init
aon admin init           # writes aon.toml + dir tree
$EDITOR aon.toml         # team name, roster, NATS URLs
```

Roster shape: `[[roles]]` blocks with `name`, `kind ∈
{manager, generalist, specialist}`, `domain`, optional
`learning`. See `templates/aon.toml.example` for a 6-role
reference.

### 1.3 Onboard your first joiner

```bash
aon admin onboard <name>                   # defaults: generalist / fullstack
aon admin onboard <name> specialist <skill>
```

`aon admin onboard` is the one-shot operator command. It:
1. Adds the role to `aon.toml`
2. Runs `aon admin reinit` (re-mints NSC auth + bootstraps NATS streams/KV + renders prompts)
3. Emits a connect token

Output is a **single curl command** (token embedded). Send it to the
joiner via 1Password share / private DM (never plain chat — token
contains credentials). Joiner pastes it. ~3 min to `claude` boot, no
engine clone, no pipx install required.

### 1.4 Bring up NATS

```bash
aon admin nats up        # starts NATS container
aon doctor               # green ✓
```

> **After `aon admin reinit`:** the resolver directory is bind-mounted
> read-only inside the container. Restart the container to pick up new JWTs:
>
> ```bash
> docker restart $(basename $PWD)-nats-1
> ```
>
> If you see repeated `authentication error` in container logs, this is the cause.

If NATS is already up and you need to re-render prompts + re-mint auth
after editing `aon.toml`:

```bash
aon admin reinit         # idempotent: auth render + bootstrap + prompts render
aon admin nats reload    # hot-reload auth.conf without container restart
```

### 1.5 Push the team repo + invite joiners

```bash
git add -A && git commit -m "init team"
gh repo create dincamihai/myteam-aon --private --source=. --push
gh repo edit dincamihai/myteam-aon --add-collaborator <gh-username>
```

Out-of-band (1Password / private DM — never plain chat):

- connect token (from `aon admin onboard` output)
- repo URL (for reference)

### 1.6 (Optional) cloudflared tunnel for remote joiners

If joiners are off-LAN, expose NATS over a Cloudflare tunnel:

```bash
cloudflared tunnel login
cloudflared tunnel create myteam-nats
cloudflared tunnel route dns myteam-nats nats.<your-domain>
# ~/.cloudflared/config.yml: ingress nats.<your-domain> → http://localhost:8080
cloudflared tunnel run myteam-nats
```

Joiners use `wss://nats.<your-domain>`. The NATS URL + bits are
embedded in the connect token by `aon admin onboard`.

Use `aon admin tunnel up|down|status` to manage the cloudflared
process lifecycle.

### 1.7 (Optional) Sandbox the team in a colima VM

For VM-level isolation per worker (DAC + systemd hardening) see
`docs/sandbox.md`.

### 1.9 Register work-repos + launch agents

Each agent works inside a code repo (their "work-repo"). Register each
role against the work-repo before launching:

```bash
cd ~/Repos/myproject        # the repo agents will work in
aon join tim .              # registers (cwd, team, tim) + installs hooks + MCP
aon join joana .
aon join rona .
```

Then launch each agent in its own terminal / tmux pane:

```bash
cd ~/Repos/myproject && aon launch tim
cd ~/Repos/myproject && aon launch joana
cd ~/Repos/myproject && aon launch rona
```

`aon launch` sets `AON_ROLE`, `AON_NATS_URL`, `AON_TEAM_KV` in env and
execs `claude`. The session-start hook arms the NATS monitor and loads
the role brief automatically on first turn.

Watch traffic:

```bash
aon monitor tim             # tail tim's subjects in a separate pane
```

### 1.10 Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `authentication error` in container logs | Container has stale JWTs after `aon auth render` | `docker restart <team>-nats-1` |
| `aon` refuses to run / wrong team detected | Not in a registered work-repo | `aon join <role> <work-repo>` first, or set `AON_TEAM_DIR` |
| `Permissions Violation` after ACL change | `_aon_nsc_ensure_user` skips existing users | `nsc delete user --account <team> <role> && aon auth render && aon creds <role>` then restart container |
| `BucketNotFoundError` in MCP server | `AON_KV_BUCKET` not in env | `aon connect <team>` — writes `AON_KV_BUCKET` to team env file |
| Peer cursors wiped on session start | Stale cursor deletion bug | Update engine to ≥ PR #57 |
| Multi-role host wrong role launched | Role selection uses cwd registry | Verify `aon doctor` shows correct role for cwd |

---

## 2. Joiner quickstart — 2 commands (~3 min)

The operator's `aon admin onboard` output gave you a curl command.
Paste it. That's the entire setup.

```bash
gh repo clone dincamihai/ai-over-nats ~/Repos/ai-over-nats
~/Repos/ai-over-nats/bin/aon connect aon://<token> <cloudflared-bits>
```

Prereq: `gh auth login` already done + read access to the engine repo.

Then:

```bash
cd <work-repo> && claude
```

What happens under the hood:

1. Clones the team-aon repo into `~/.aon/teams/<team>/repo/` (or
   symlinks it if you ran from inside a matching checkout).
2. Writes creds to `~/.aon/teams/<team>/creds/<role>.creds`
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
Re-running `aon connect` migrates any legacy global team hooks out
automatically.

Add `aon` to PATH:

```bash
export PATH="$HOME/Repos/ai-over-nats/bin:$PATH"
```

> **`$ANTHROPIC_API_KEY` warning is harmless.** Claude subscription
> users (Code / Pro / Max) `/login` inside `claude` on first run.

### 2.1 Operator-side observability during a trial

While a joiner is running, the operator gets live visibility with:

```bash
aon monitor <role>          # tails agents.<role>.events + inbox + their boards
# or, in a fresh shell already exporting TEAM_ALPHA_ROLE:
aon monitor                 # role defaults from env
```

Run one pane per role you want to watch (joiner role, coordinator,
mentor). The monitor pulls NATS URL + creds from the team's
`aon.toml` + `~/.aon/teams/<team>/creds/<role>.creds` automatically — no
manual env setup.

---

## 2.5 Trial-test runbook (operator + one joiner, ~10 min)

Use this for adding a new joiner mid-cycle (e.g. trying a generalist
role on an existing team) without re-bootstrapping the whole substrate.

**Operator side** (in the per-team repo):

```bash
# 1. Onboard the new role (adds to roster, reinit, emits token)
aon admin onboard <name> generalist <domain>   # e.g. aon admin onboard vahid generalist python

# 2. (If NATS is already up) reload auth so the new user is recognised
aon admin nats reload

# 3. Verify the role can connect
aon doctor
```

Out-of-band to the joiner: the connect token from step 1's output.

**Joiner side**:

```bash
aon connect aon://<token> <bits>
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
rm ~/.aon/teams/<team>/creds/<name>.creds

# Operator (only if dropping the role permanently)
$EDITOR aon.toml              # remove the [[roles]] block
aon admin reinit
aon admin nats reload
```

---

## 3. Agent first-turn (when claude boots in `<work-repo>`)

You are a worker agent. Read this once.

### 3.1 What you should already have

Your human ran `aon connect <token> <bits>` before launching you.
That command:

- saved creds to `~/.aon/teams/<team>/creds/<role>.creds` (chmod 600)
- registered `(<work-repo>, team, role)` in `~/.aon/work-repos.json`
- installed MCP server in `<work-repo>/.mcp.json` (gitignored) + hooks in `<work-repo>/.claude/settings.json` (COMMITTED — portable via `aon hook`)
- verified a NATS handshake as your role

The MCP server resolves your role from cwd at startup. On your first
turn, call `get_role_brief()` to load your role-specific operating
context. If the MCP server isn't connected, tell the human to run
`aon doctor` and `aon connect` from this work-repo.

### 3.2 First-turn sequence

1. **Resolve identity.**
   - `$TEAM_ALPHA_ROLE` = your role.
   - `$TEAM_ALPHA_NATS_URL` = bus URL.
   - `$TEAM_ALPHA_CREDS` = path to your creds file.
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
| VM sandbox | `docs/sandbox.md` |
| `aon` CLI reference | `aon help` |

### 3.5 You do NOT need to

- Install anything. Your human did it.
- Hold credentials in chat. They live at
  `~/.aon/teams/<team>/creds/<role>.creds`.
- Maintain a parallel log. Substrate publishes ARE the log.
- Run `aon admin reinit` / `cloudflared` / `docker compose` —
  operator paths.

---

## 4. `aon` CLI reference

### ADMIN (operator)

```
aon admin init                      create aon.toml + dir tree (one-time)
aon admin onboard NAME [KIND]       add role + reinit + emit connect token
                                    defaults: KIND=generalist, DOMAIN=fullstack
                                    composes: roster + reinit + token emit
aon admin reinit                    re-mint NSC auth + bootstrap NATS streams/KV
                                    + render prompts. idempotent, re-run any time
                                    aon.toml changes.
aon admin revoke [ROLE|list|clear]  manage revoked user JWTs
aon admin nats SUBCMD               docker-compose wrapper: up|down|logs|status|reload
aon admin tunnel SUBCMD             cloudflared lifecycle: up|down|status
```

### JOIN

```
aon connect TOKEN BITS              one-shot joiner setup from operator's token + bits
                                    clones team repo, places creds, probes NATS handshake,
                                    installs MCP + hooks in work-repo.
                                    TOKEN = aon://<base64> from `aon admin onboard`
                                    BITS  = cloudflared URL fragment (out-of-band)
```

### RUNTIME

```
aon launch ROLE [WORK_REPO]         set env, install hooks, exec claude as ROLE
aon monitor [ROLE]                  tail role's NATS subjects in a separate pane
                                    resolves role + URL + creds from cwd registry;
                                    falls back to operator-side aon.toml + arg/$TEAM_ALPHA_ROLE
aon pub SUBJECT PAYLOAD             publish a message (injects auth from registry)
aon sub SUBJECT                     subscribe to a subject
aon req SUBJECT PAYLOAD             request-reply
aon doctor                          sanity-check local setup
aon mcp-server [aon|board]          run the MCP server (aon substrate or task board)
aon hook NAME [args]                portable hook launcher (used by settings.json hooks)
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
  .tasks/                                     ← team's task cards
  docs/                                       ← team-specific runbooks
```

---

## License

Internal. Not yet public.
