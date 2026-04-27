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
aon onboard <name> <cloudflared-bits>                   # defaults: generalist / fullstack
aon onboard <name> <cloudflared-bits> specialist <skill>
```

`<cloudflared-bits>` = current 4-word random subdomain piece of your
trycloudflare URL (e.g. `transportation-repeated-ppm-bobby` for
`wss://transportation-repeated-ppm-bobby.trycloudflare.com`). Bits
travel out-of-band only — they must NEVER live in `aon.toml` or any
committed file.

Composes 8 steps idempotently: roster + render + auth + creds + NATS
up + **local handshake probe** + commit/push + token emit. ~30s on a
warm operator box. Failure-safe — any step's failure aborts with a
clear hint.

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
aon creds --all          # writes ~/.team-alpha/<role>.password (chmod 600) for every role
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
- role password (`~/.team-alpha/<role>.password` from §1.5)
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

The engine repo is private (no public install URL) — joiner clones
directly, then runs `aon` from the checkout. Add it to PATH if you
want rotation commands later:

```bash
export PATH="$HOME/Repos/ai-over-nats/bin:$PATH"
```

Then:

```bash
cd <work-repo> && claude
```

What happens under the hood: clones the team-aon repo to
`~/Repos/<team>-aon`, writes `~/.team-alpha/<role>.password` (chmod
600), builds the NATS URL from the bits, probes the handshake, and (if
`aon` is on PATH) stamps your work-repo via `aon join`.

**No engine clone. No pipx install.** The script is self-contained.

If you'd rather have `aon` on PATH for tunnel rotations and other
operations, install it after the first run:

```bash
pipx install git+https://github.com/dincamihai/ai-over-nats
```

(Don't have `pipx`? Linux: `sudo apt install pipx` or
`pip3 install --user pipx && pipx ensurepath`. macOS: `brew install pipx`.)

### Tunnel rotated? Run `aon set-nats-url <new-bits>`

When the operator DMs you new cloudflared bits, you DON'T re-onboard.
With `aon` installed:

```bash
aon set-nats-url <new-cloudflared-bits>
# restart claude in your work-repo
```

Without `aon`, re-paste the embedded one-liner with the new bits as arg 2 —
the script detects existing setup and goes into rotation mode (no
re-clone, no re-prompt).

> **`$ANTHROPIC_API_KEY` warning is harmless.** Claude subscription
> users (Code / Pro / Max) `/login` inside `claude` on first run.

### 2.0 (advanced) granular joiner flow

If you don't have a token (or want manual control):

```bash
# clone team-aon repo + work-repo, place creds, run aon join
git clone <team-repo-url> ~/Repos/<team>-aon
mkdir -p ~/.team-alpha && chmod 700 ~/.team-alpha
echo -n '<48-hex from operator>' > ~/.team-alpha/<role>.password
chmod 600 ~/.team-alpha/<role>.password

cd ~/Repos/<team>-aon                    # IMPORTANT: aon resolves aon.toml from cwd
aon join <role> /absolute/path/to/<work-repo>
# at NATS URL prompt: must be wss:// (not https://)
cd <work-repo> && claude
```

`aon join` saves creds, stamps `.claude/settings.json` + `.mcp.json`,
verifies a NATS handshake, symlinks `<work-repo>/CLAUDE.md` to your
role brief, and prints the launch line.

### 2.1 Operator-side observability during a trial

While a joiner is running, the operator gets live visibility with:

```bash
aon monitor <role>          # tails agents.<role>.events + inbox + their boards
# or, in a fresh shell already exporting TEAM_ALPHA_ROLE:
aon monitor                 # role defaults from env
```

Run one pane per role you want to watch (joiner role, coordinator,
mentor). The monitor pulls NATS URL + creds from the team's
`aon.toml` + `~/.team-alpha/<role>.password` automatically — no
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
aon creds <name>              # → ~/.team-alpha/<name>.password (chmod 600)

# 4. (If NATS is already up) reload auth so the new user is recognised
aon nats up                   # restart nats container with new auth.conf

# 5. Verify the role can connect with its password
aon doctor
```

Out-of-band to the joiner: role name, role password (cat
`~/.team-alpha/<name>.password`), team repo URL, NATS URL.

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
rm ~/.team-alpha/<name>.password

# Operator (only if dropping the role permanently)
$EDITOR aon.toml              # remove the [[roles]] block
aon prompts render && aon auth render && aon auth set-passwords
aon nats up                   # reload
```

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
aon onboard NAME BITS [KIND] [DOMAIN]  one-shot operator onboarding (recommended)
                               BITS = current cloudflared subdomain (4-word piece)
                               composes add-role + render + auth + creds + nats up
                               + handshake probe + commit/push + token emit
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
aon join ROLE WORK_REPO        full joiner setup (creds, .mcp.json, hooks,
                               CLAUDE.md symlink, NATS handshake)
aon join-link TOKEN BITS       one-shot joiner setup from operator's token + bits
                               (recommended) — clones team repo, places creds,
                               runs aon join automatically. Re-run with new BITS
                               to rotate NATS URL only (no re-clone).
aon set-nats-url BITS          joiner-side tunnel rotation (no re-clone, no creds
                               change). Use --role NAME if multiple roles on box.
aon monitor [ROLE]             tail role's NATS subjects in a separate pane
                               (env baked from aon.toml + ~/.team-alpha/<role>.password;
                               role defaults from $TEAM_ALPHA_ROLE)
aon apparmor SUB               personal AppArmor overrides (sync|show|reload|watch)
```

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
