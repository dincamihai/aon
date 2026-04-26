---
column: In Progress
created: 2026-04-26
order: 221
---

# Card 221 — Team session onboarding (cloudflared NATS + one-script joiner)

Mihai is running the first multi-human team-alpha session
tomorrow (2026-04-27). Five+ colleagues join from their own
laptops over a public-internet NATS substrate, each picks one of
the existing six roles, and starts working real cards across
multiple repos (saas, terraform, backend, api, ui).

Smooth onboarding is the whole point — if joiners can't get past
the substrate handshake, the session falls apart.

## What we're building

Two artifacts:

1. **`docs/team-session-runbook.md`** — split runbook for the two
   audiences:
   - **Admin (Mihai)**: bring up NATS w/ websocket, cloudflared
     tunnel from laptop, distribute role passwords, smoke test.
   - **Joiner (everyone else)**: clone repo, run one script, start
     claude in their own work repo. Three commands.

2. **`scripts/join.sh <role> <work-repo>`** — single-shot joiner
   onboarding. Idempotent. Does:
   - prereq checks: claude, nats, jq, python3, pipx
   - asks for role password (hidden), saves to
     `~/.team-alpha/<role>.password` (chmod 600)
   - asks for `wss://...` NATS URL (with default), saves env to
     `~/.team-alpha/<role>.env`
   - installs `team-alpha-mcp` venv at
     `<ai-over-nats>/mcp-server/.venv` (one-time)
   - installs `board-tui-mcp` via pipx from
     `https://github.com/dincamihai/board-tui.git` (one-time)
   - stamps `.mcp.json` into the joiner's `<work-repo>` registering
     both MCPs with paths resolved for THEIR machine
   - stamps `.claude/settings.json` into the work repo via
     `scripts/hooks/install.sh`
   - symlinks `<work-repo>/CLAUDE.md` → role brief (skips if file
     already exists — no clobber)
   - performs `nats rtt` handshake — fails loudly if substrate
     unreachable
   - prints exact `cd <work-repo> && claude` command

## Architecture choices

- **NATS over WebSocket on :8080**, cloudflared exposes as
  `wss://nats.<admin-domain>`. Reasons: (a) joiners don't need
  client-side cloudflared install; (b) TCP cloudflared tunnels
  require per-joiner `cloudflared access tcp ...` calls which is
  too much friction; (c) NATS supports WS natively; (d) corporate
  firewalls let WSS through that block raw 4222.
- **Joiners run claude in their own work repo**, not in a fixed
  `~/team-alpha/<role>/` workdir. The script stamps the work repo
  with the right `.claude/settings.json` + `.mcp.json` so the
  team-alpha tools + hooks are available wherever they actually
  do code.
- **Role passwords distributed out of band** (1Password etc.).
  Cleartext in `~/.team-alpha/<role>.password`, chmod 600. JWT
  flow lands later (see card on NSC migration).
- **Substrate is single-host**: Mihai's laptop runs NATS +
  cloudflared. If laptop sleeps, session pauses. EC2 is the
  next-step upgrade if recurring.

## Files

- `docs/team-session-runbook.md` — runbook (new)
- `scripts/join.sh` — joiner onboarding script (new)
- `.tasks/team-alpha-team-session-onboarding.md` — this card

Out-of-scope (deferred):
- Per-colleague persona overlays (`<role>.local.md`) — colleagues
  edit base brief on a branch for tomorrow if needed.
- Multi-host NATS infra (EC2 / Fargate) — cloudflared is enough.
- Defect 216 (resume-prompt hijack) — joiners are told to ignore.
- Defect 217 (maya done-mover) — workaround is human nudge.

## Acceptance

- [ ] Mihai walks the admin block and gets to a working
      cloudflared tunnel exposing NATS over WSS.
- [ ] A second person (smoke) clones the repo, runs
      `bash scripts/join.sh priya ~/Repos/saas`, and gets a green
      handshake without admin help.
- [ ] `cd ~/Repos/saas && claude` opens a session with the
      team-alpha + board MCP tools available.
- [ ] First turn fires SessionStart hook, opens Monitor on
      subscribed subjects, publishes `agents.priya.events
      {kind:"hello"}`.
- [ ] Joiner can `mcp__team-alpha-board__list_tasks` and see the
      shared inbox.
- [ ] Joiner can DM another role and the message lands.
- [ ] AUDIT trace from the admin side shows all the hello events
      from joiners as they come online.

## Refs

- `docs/onboarding-per-role.md` — deeper per-role config (still
  useful for post-session deeper dives).
- `MODEL.md` — substrate primer.
- Card 220 — post-MVP delegate + SDK pivot. Tomorrow's session
  uses the pre-pivot flow (host CLI per role, no containers).
- Cloudflare Tunnel docs — used by admin.
- `~/Repos/board-tui` — source of board-tui-mcp.
