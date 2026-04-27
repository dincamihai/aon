---
description: Full mid-cycle trial-test runbook for adding a new joiner to an existing aon team — operator side end-to-end, with monitor panes wired and the share block ready to send. Use for first-time joins, generalist trials, or any "run someone through onboarding without re-bootstrapping the substrate". Trigger phrases include "trial test", "trial run with <name>", "run a trial", "test <name> on the team", "onboard <name> for a trial", "do a mob session with <name>".
---

# aon: trial-test runbook

End-to-end operator workflow for a one-shot trial of a new joiner on
an existing team. ~10 min wall time on the operator side, ~5 min on
the joiner side. Assumes the team substrate is already up.

## Phase 1 — operator setup (~5 min)

In the per-team aon repo (`cd ~/Repos/<team>-aon`):

1. **Add the role.** Use `/aon:add-role` (composes
   `aon add-role` + render + creds + nats up + share block). If you
   already ran `/aon:add-role`, skip to phase 2.

2. **Confirm the live tunnel URL** (in case cloudflared restarted
   recently):

   ```bash
   grep '^ws_url' aon.toml
   pgrep -af cloudflared
   ```

   If `aon.toml` shows a stale URL, run `/aon:rotate-tunnel` first.

3. **Compose share block.** Out-of-band only (1Password / private
   DM). Never plain chat.

   ```
   Team:        <team-name>
   Role:        <name>
   Repo:        <team-repo-url>
   NATS URL:    <ws_url>
   Password:    $(cat ~/.team-alpha/<name>.password)
   Engine:      git clone https://github.com/dincamihai/ai-over-nats ~/Repos/ai-over-nats
                pipx install --editable ~/Repos/ai-over-nats
   ```

4. **Open monitor panes.** One per role you want to watch live:

   ```bash
   # pane 1
   aon monitor <name>          # joiner's traffic

   # pane 2 (in fresh shell)
   aon monitor maya            # or your manager role
   ```

   Each monitor tails `agents.<role>.events` + inbox + that role's
   subscribed boards. Hello event lands within seconds of joiner
   running `claude`.

## Phase 2 — joiner side (~5 min, on their box)

Send them `/aon:join` if they have it; otherwise paste the share
block from phase 1.4 plus this minimal sequence:

```bash
# one-time engine install
git clone https://github.com/dincamihai/ai-over-nats ~/Repos/ai-over-nats
pipx install --editable ~/Repos/ai-over-nats

# clone team-aon repo + place creds
git clone <team-repo-url> ~/Repos/<team>-aon
mkdir -p ~/.team-alpha && chmod 700 ~/.team-alpha
echo -n '<password content>' > ~/.team-alpha/<name>.password
chmod 600 ~/.team-alpha/<name>.password

# join (must run from team-aon repo dir)
cd ~/Repos/<team>-aon
aon join <name> <absolute path to their work repo>
# at NATS URL prompt: accept default (wss://...)

# launch
cd <work-repo> && claude
```

## Phase 3 — verify (operator side)

When joiner runs `claude`, you should see in the monitor pane within
~30s:

1. `agents.<name>.events {kind: "hello"}` — onboard hook fired.
2. `agents.<name>.events {kind: "status", state: "..."}` — first
   status emit.

If silence for >60s, run `/aon:diagnose-handshake` for `<name>`.

## End of trial — cleanup (only if dropping the role)

Operator side:
```bash
$EDITOR aon.toml              # remove the [[roles]] block
aon prompts render && aon auth render && aon auth set-passwords
aon nats up                   # reload
git add -A && git commit -m "Drop role: <name>" && git push
```

Joiner side:
```bash
rm ~/.team-alpha/<name>.password ~/.team-alpha/<name>.env
# optionally remove work-repo .claude/settings.json + .mcp.json
```

## Common errors

- **role 'X' not in roster** when joiner runs `aon join` → they're
  not in the team-aon dir. They must `cd ~/Repos/<team>-aon` first.
  See `/aon:join`.
- **NATS handshake failed** → see `/aon:diagnose-handshake`.
- **Operator-path leak in joiner's `<work-repo>/.claude/settings.json`**
  → engine pre-PR-#26 bug. See `/aon:settings-recovery`.
