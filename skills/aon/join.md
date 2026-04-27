---
description: First-time joiner walkthrough for the aon engine — installs prereqs, clones the engine and the team-aon repo, places the role password, runs aon join, verifies the NATS handshake, and prints the launch line. Use whenever the user says they're joining a team for the first time, has just received a share block from an operator, or asks "set me up", "aon join", "how do I join". Trigger phrases include "I'm joining a team", "set me up as <role>", "aon join", "joining the trial", "got an invite to join", "first time joiner".
---

# aon: first-time joiner walkthrough

You received from the operator out-of-band: role name, role password
(48-char hex), team-aon repo URL, NATS URL (wss://...).

Run all steps on **your** machine. Each step is mandatory unless
marked optional.

## Step 0 — Inputs

Confirm with the user:

- `<role>` — your role name (must match what the operator added).
- `<password>` — 48 hex chars, no surrounding quotes or whitespace.
- `<team-repo-url>` — e.g. `https://github.com/<owner>/<team>-aon`.
- `<nats-url>` — must start with `wss://` (or `nats://` for
  loopback). Never `https://` — `nats` CLI doesn't speak HTTP.
- `<work-repo>` — local path where you'll run `claude` (e.g. an
  existing scratch project repo). Must already exist on disk; `aon
  join` does not clone work-repos.

## Step 1 — Engine install (one-time)

```bash
# clone engine + put on PATH
git clone https://github.com/dincamihai/ai-over-nats ~/Repos/ai-over-nats
pipx install --editable ~/Repos/ai-over-nats
aon help        # verify
```

If `pipx` missing: `brew install pipx && pipx ensurepath`.

## Step 2 — Clone the team-aon repo

```bash
git clone <team-repo-url> ~/Repos/<team>-aon
```

This holds the team's `aon.toml` (roster + NATS URL), your role
brief in `agent-prompts/<role>.md`, the auth blueprint, and task
cards.

## Step 3 — Place your password file

```bash
mkdir -p ~/.team-alpha && chmod 700 ~/.team-alpha
echo -n '<password>' > ~/.team-alpha/<role>.password
chmod 600 ~/.team-alpha/<role>.password
```

`echo -n` (no trailing newline). chmod 600 is required.

## Step 4 — Run `aon join`

**From inside the team-aon repo.** This is critical — `aon`
resolves `aon.toml` from the current directory.

```bash
cd ~/Repos/<team>-aon
aon join <role> /absolute/path/to/<work-repo>
```

At the **NATS URL** prompt: accept the default (it's read from the
team's `aon.toml`). Don't type `https://` — must be `wss://`.

If you get **`✗ role '<role>' not in roster`**, you're in the wrong
directory. `cd ~/Repos/<team>-aon` and retry.

Ignore the `⚠ $ANTHROPIC_API_KEY unset` warning — Claude
subscription users log in via `/login` inside `claude` on first run.
No API key needed.

## Step 5 — What `aon join` did

You should now have:

- `~/.team-alpha/<role>.env` — env vars (source in shell rc if you
  want them persistent).
- `<work-repo>/.mcp.json` — both MCP servers wired with your role's
  creds.
- `<work-repo>/.claude/settings.json` — engine hooks with env
  prefix baked in.
- `<work-repo>/CLAUDE.md` — symlink to your role brief.

It also published a `kind:probe` event to NATS — if the handshake
failed, **stop here** and DM the operator with the failure
message. They'll run `/aon:diagnose-handshake`.

## Step 6 — Launch claude

```bash
cd /absolute/path/to/<work-repo>
claude
```

First boot may prompt `/login` — pick your subscription account.

## Step 7 — First-turn discipline

Once claude is running:

1. **Ignore** the global "Pending resume prompts" block if it
   appears. Those are the operator's personal notes, unrelated to
   your role.
2. Open the **Monitor** on your role's NATS subjects (the onboard
   hook tells you exactly which ones).
3. Call **`a2a_inbox()`** to pick up tasks queued while you were
   offline.
4. Wait for either operator instruction or a dispatch event from
   Monitor.

See `/aon:first-turn` for full discipline.

## Common errors

| Symptom | Skill / Fix |
|---|---|
| `✗ role 'X' not in roster` | wrong cwd. `cd ~/Repos/<team>-aon`. |
| NATS handshake failed | DM operator → `/aon:diagnose-handshake`. |
| Hook commands point at `/Users/<operator>/` | `/aon:settings-recovery`. |
| Tunnel URL stale | DM operator → `/aon:rotate-tunnel`. |
| `→` literal file appeared in cwd | you copy-pasted a comment glyph. `rm "→"` and re-run the bare command. |
