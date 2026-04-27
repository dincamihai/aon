---
description: Handle ephemeral cloudflared trycloudflare tunnel URL changes for an aon team. Detects the live tunnel URL, patches aon.toml, commits and pushes, and tells joiners how to refresh. Use this whenever the cloudflared tunnel restarted, the trycloudflare URL changed, or joiners suddenly can't reach NATS. Trigger phrases include "tunnel restarted", "trycloudflare URL changed", "joiner can't connect", "rotate tunnel URL", "NATS URL changed".
---

# aon: rotate cloudflared tunnel URL

Operator-side. Run when the team's `wss://...trycloudflare.com` URL
has changed (cloudflared restart) and joiners' clients are still
hitting the old, dead URL.

## Steps

1. **Confirm cloudflared is up.**

   ```bash
   pgrep -af cloudflared
   ```

   Expect a process line like
   `cloudflared tunnel --url http://localhost:8080 ...`. If nothing,
   cloudflared isn't running — start it before continuing.

2. **Read the current URL from the tunnel log.**

   The log file is whatever `--logfile` was passed. Common location:
   `/tmp/cloudflared-natsbus.log` or similar.

   ```bash
   grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared-*.log | tail -1
   ```

   That's the live URL. Store as `NEW_URL`.

3. **Read the old URL from `aon.toml`.**

   ```bash
   cd ~/Repos/<team>-aon
   grep '^ws_url' aon.toml
   ```

   The diff between old and `NEW_URL` is what you'll patch.

4. **Patch `aon.toml`.**

   ```bash
   sed -i '' "s|<old-subdomain>|<new-subdomain>|" aon.toml
   # or hand-edit: [nats] ws_url = "wss://<NEW_URL host>"
   ```

   Verify:

   ```bash
   grep '^ws_url' aon.toml
   ```

5. **Commit + push.**

   ```bash
   git add aon.toml
   git commit -m "Rotate cloudflared tunnel URL"
   git push origin main
   ```

6. **DM all current joiners** out-of-band:

   > Tunnel URL rotated. Refresh on your box:
   > ```
   > cd ~/Repos/<team>-aon && git pull
   > rm ~/.team-alpha/<role>.env
   > aon join <role> <work-repo>
   > ```
   > At the NATS URL prompt, accept the new default.

7. **Verify your own connection** with the new URL:

   ```bash
   PW=$(cat ~/.team-alpha/<your-role>.password) NATS_PASSWORD="$PW" \
   nats --server "wss://<NEW_URL>" --user <your-role> --timeout 5s \
        server check connection
   ```

   Should print `OK Connection OK`.

## Permanent fix

trycloudflare URLs rotate every cloudflared restart. For a stable URL:

```bash
cloudflared tunnel login
cloudflared tunnel create <team>-nats
cloudflared tunnel route dns <team>-nats nats.<your-domain>
# config.yml: ingress nats.<your-domain> → http://localhost:8080
cloudflared tunnel run <team>-nats
```

Joiners then use `wss://nats.<your-domain>` permanently.

## Common errors

- **"connection failed: EOF"** on \`nats\` CLI test — server-side
  auth issue (not URL). See `/aon:diagnose-handshake`.
- **HTTP 405 on curl test** — that's normal. WebSocket upgrade
  expected; `405` means the server is alive.
