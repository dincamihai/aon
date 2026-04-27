---
description: Operator-side guided onboarding for adding a new role to an aon team — appends the role to aon.toml, re-renders prompts and auth, materializes creds, restarts NATS, and composes the out-of-band share block. Use this whenever the user wants to add a role, onboard a joiner, run a trial test, or invite someone to the team. Trigger phrases include "add a role", "onboard <name>", "invite <name>", "trial test", "add <name> to the team".
---

# aon: add a role

Operator-side workflow. Prerequisite: you are inside the per-team aon
repo (where `aon.toml` lives). If unsure: `cd ~/Repos/<team>-aon`.

## Inputs

Ask the user (only what's missing):

- `<name>` — role name, lowercase, alphanumeric.
- `<kind>` — one of `manager`, `generalist`, `specialist`.
- `<domain>` — primary skill. Recognized by MCP `acl.py`:
  `python | go | ui | terraform | aws | fullstack | manager`.
  Other strings work for prompts/ACL but break MCP skill routing —
  warn the user.
- `<learning>` (optional, generalist only) — second skill, growth track.

## Steps

1. **Append to roster.**

   ```bash
   aon add-role <name> <kind> <domain>
   ```

   `add-role` is idempotent on `<name>` — re-running won't overwrite.
   To change `<kind>` or `<domain>` for an existing role, edit
   `aon.toml` directly.

2. **Re-render briefs and ACL.**

   ```bash
   aon prompts render
   aon auth render
   aon auth set-passwords     # idempotent: only fills new placeholders
   ```

3. **Materialize the role's local password file.**

   ```bash
   aon creds <name>           # writes ~/.team-alpha/<name>.password (chmod 600)
   ```

   **Do not** put `→` or any other glyph after the command — copy-paste
   from comments breaks. Run it bare.

4. **Reload NATS so the new user is recognized.**

   ```bash
   aon nats up                # restart container with fresh auth.conf
   ```

   If the container was already up, this restarts it. If it was down,
   it brings it up.

5. **Verify.**

   ```bash
   aon doctor
   ```

   Should print all green. If `<name>` connect check fails: server
   didn't reload (re-run `aon nats up`) or the password file content
   doesn't match `nats/.passwords` `<NAME>=` line.

6. **Commit + push the team-aon repo** so joiners get the new
   roster on `git pull`.

   ```bash
   git add aon.toml agent-prompts/ nats/auth.conf.example
   git commit -m "Add role: <name> (<kind>/<domain>)"
   git push origin main
   ```

7. **Compose the out-of-band share block.** Send via 1Password /
   private DM — never plain chat. Format:

   ```
   Team:        <team-name>
   Role:        <name>
   Repo:        <team-repo-url>
   NATS URL:    <ws_url from aon.toml>
   Password:    <content of ~/.team-alpha/<name>.password>
   Engine:      git clone https://github.com/dincamihai/ai-over-nats ~/Repos/ai-over-nats
                pipx install --editable ~/Repos/ai-over-nats
   ```

   Read the password from the file:

   ```bash
   cat ~/.team-alpha/<name>.password
   ```

   Send only the hex content (24 bytes / 48 hex chars). No newline,
   no surrounding quotes.

8. **(Optional) start a monitor pane** to watch the joiner connect:

   ```bash
   aon monitor <name>
   ```

   Hello event lands within seconds of the joiner running `claude`.

## Common errors

- **"role 'X' already in roster"** — `add-role` is append-only.
  Edit `aon.toml` to change an existing block.
- **"backend / new-domain not in MCP skill routing"** — domain
  string is opaque to `acl.py`. Tasks posted to
  `board.tasks.<domain>.pending` won't be auto-routed by Maya. Use
  one of the recognized skills, or extend `acl.py` first (see
  `team-alpha-roster-multi-skill-schema.md`).
- **NATS handshake fails after restart** — see `/aon:diagnose-handshake`.
