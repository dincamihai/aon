# team-alpha — session runbook (host + joiners)

How to run a multi-human team-alpha session. Two audiences: the
**admin** (one person — usually Mihai) who hosts the substrate,
and **joiners** (everyone else) who pick a role and connect. Admin
block runs once per session. Joiner block is what each colleague
does on their own laptop — clone, one script, start claude in
their own work repo. That's it.

> Deeper reading: [`onboarding-per-role.md`](onboarding-per-role.md)
> for full per-role config, [`MODEL.md`](../MODEL.md) for the
> substrate primer.

---

## Prereqs (everyone)

| Tool             | Install                                        |
|------------------|------------------------------------------------|
| `claude` CLI     | `npm install -g @anthropic-ai/claude-code`     |
| `nats` CLI       | `brew install nats-io/nats-tools/nats`         |
| `git`, `python3` | already on macOS / standard dev box            |
| Anthropic key    | set `ANTHROPIC_API_KEY` in your shell rc       |

Joiners DO NOT need: docker, NATS server install, Cloudflare
account, or any of the admin paths.

---

## ADMIN — before colleagues join (~15 min)

You hold the substrate, the cloudflared tunnel, and the role
passwords.

### A1. Bring up NATS w/ websocket enabled

Edit `nats/nats-server.conf`, add a websocket block:

```
websocket {
  port: 8080
  no_tls: true   # cloudflared wraps this in TLS
}
```

Restart + verify:

```bash
docker compose up -d nats
curl -s http://127.0.0.1:8222/healthz   # {"status":"ok"}
```

### A2. Bootstrap streams + KV (idempotent)

```bash
export NATS_URL=nats://localhost:4222
export NATS_ADMIN_USER=sysadmin
export NATS_ADMIN_PASSWORD=<from your secret manager>
bash scripts/bootstrap.sh
```

### A3. Start cloudflared tunnel

One-time setup (skip if already done):

```bash
brew install cloudflared
cloudflared tunnel login                         # browser OAuth
cloudflared tunnel create team-alpha-nats
cloudflared tunnel route dns team-alpha-nats nats.<your-domain>
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: <uuid printed by `tunnel create`>
credentials-file: /Users/<you>/.cloudflared/<uuid>.json
ingress:
  - hostname: nats.<your-domain>
    service: http://localhost:8080
  - service: http_status:404
```

Run (foreground; or `nohup` to detach):

```bash
cloudflared tunnel run team-alpha-nats
```

Verify from a second terminal:

```bash
nats --server wss://nats.<your-domain> --user sysadmin --password ... rtt
```

### A4. Distribute role assignments + passwords

Roles to choose from:

```
maya   — dispatcher / coordinator
priya  — terraform / AWS
raj    — Python / language tools
lin    — Python + Node + TypeScript
sam    — UI / frontend
diego  — Go + light terraform
```

For each colleague, send via 1Password / Bitwarden / private DM
(**never plain chat / email / git**):

- assigned role
- role password (from `/tmp/team-alpha-passwords.txt`)
- NATS URL: `wss://nats.<your-domain>`
- ai-over-nats repo URL

### A5. Open a backchannel

Slack / Discord / Zoom audio. Humans coordinate out-of-band; the
substrate is for agents talking to agents.

### A6. Smoke test as a joiner

In a fresh terminal pretend to be a joiner. Walk the joiner flow
below end-to-end. If you reach a working `claude` session that
sees the team-alpha MCP tools, you're done.

---

## JOINER — three commands (~5 min)

What you should have received from the admin:
- role name (e.g. `priya`)
- role password
- NATS URL (e.g. `wss://nats.<admin-domain>`)
- ai-over-nats repo URL

### J1. Clone the substrate repo

This is config + scripts + role briefs. You won't write code in it.

```bash
git clone <ai-over-nats-repo-url> ~/Repos/ai-over-nats
```

### J2. Run the join script — pointed at your work repo

`<work-repo>` is the actual code repo where you'll do the work
(e.g. `~/Repos/saas`, `~/Repos/terraform`, etc). The script
stamps `.claude/settings.json` + `.mcp.json` into that repo so
that when you `cd <work-repo> && claude`, the team-alpha tools +
hooks are wired up.

```bash
bash ~/Repos/ai-over-nats/scripts/join.sh <your-role> <work-repo>
# example:
bash ~/Repos/ai-over-nats/scripts/join.sh priya ~/Repos/saas
```

The script (interactive):
1. asks for your role password (hidden input)
2. asks for the `wss://...` URL (or accepts default)
3. checks `ANTHROPIC_API_KEY` is set
4. saves your creds to `~/.team-alpha/<role>.password` (chmod 600)
5. stamps `.claude/settings.json` + `.mcp.json` into `<work-repo>`
   with paths resolved for **your** machine (no leftover
   `/Users/mid`)
6. does an `nats rtt` handshake to verify the substrate is
   reachable as your role
7. prints the exact command to launch claude

If `nats rtt` fails the script stops and tells you what's wrong
(wrong password, tunnel down, wrong URL). Ping admin.

### J3. Start claude in your work repo

```bash
cd <work-repo>
claude
```

That's it. First turn:
- SessionStart hooks open a Monitor on your subscribed subjects
  (your inbox, board cards in your skills, broadcasts)
- A handshake event fires on `agents.<role>.events {kind:"hello"}`
- The team-alpha MCP server is registered → tools like
  `mcp__team-alpha__a2a_send_task`, `mcp__team-alpha-board__list_tasks`
  available immediately

You can now:
- ask your agent to read the board: "Show pending tasks for me"
- DM another role: "DM priya: free for a chat?"
- drop a task card: "Create a board task: refactor auth middleware"
- watch live: in another terminal,
  `nats --server wss://... --user <role> --password <pw> sub 'AUDIT.>'`

---

## Known limits (today)

- **Roles fixed at 6**. Pick from `{maya, raj, lin, sam, diego, priya}`.
- **No container isolation** — agent runs on your host w/ full
  `Edit/Write/Bash` powers. Don't drop untrusted task cards.
- **Resume-prompt hijack** (defect 216): first turn may show a
  global "pending resume prompts" block. Ignore.
- **Maya auto-done-move flaky** (defect 217): if a card sticks in
  `in-progress/` after worker completes, nudge maya by hand.
- **Persona = markdown edits**. Want a personality tweak? Edit
  `scripts/agent-prompts/<your-role>.md` on a branch, PR back if
  useful. No live persona UI.

---

## End of session (admin)

- Stop cloudflared tunnel (Ctrl-C)
- `docker compose down nats` (optional — KV state persists across
  restarts via JetStream volume)
- Capture lessons in your daily note. Look at AUDIT for what
  actually happened during the session.
