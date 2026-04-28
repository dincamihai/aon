---
column: Done
created: 2026-04-28
completed: 2026-04-28
order: 110
priority: normal
---

# `aon join` clobbers existing NATS URL when prompt is empty-Enter'd

`cmd_join` interactively prompts for NATS URL with the current value as
default in brackets, e.g.:

```
NATS URL [wss://nats.example.com]: ▮
```

If the operator hits Enter (intending "keep current"), the script
substitutes the **placeholder shown in brackets**, not the previously
stored value. Result: a working URL gets overwritten with the example
placeholder, and the next handshake fails.

## Repro

1. `aon onboard mihai <real-bits>` — env file has working URL.
2. Re-run `aon join mihai <repo>`.
3. Hit Enter at the URL prompt.
4. `cat ~/.aon/teams/<team>/creds/mihai.env` → URL is now
   `wss://nats.example.com`.

## Expected

Empty input ⇒ keep the previously stored URL from the env file. The
bracketed default in the prompt should reflect the actual current value
(read from `mihai.env`), not a generic placeholder.

## Fix

In `cmd_join` (around the URL prompt):

- Read existing `TEAM_ALPHA_NATS_URL` from `~/.aon/teams/<team>/creds/<role>.env`
  before prompting.
- Show that value as the bracketed default.
- If user input is empty, reuse the existing value (don't write the
  placeholder).
- Refuse to write `wss://nats.example.com` or
  `wss://YOUR-CURRENT-TUNNEL.trycloudflare.com` literal — these are
  placeholders, not real URLs.

## Out of scope

- Adding a non-interactive `--url` flag (could be a follow-up).
