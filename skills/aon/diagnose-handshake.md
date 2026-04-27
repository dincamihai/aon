---
description: Diagnose why aon join's NATS handshake is failing. Walks through the four common failure modes (stale auth, scheme typo, dead tunnel, password mismatch) and outputs a one-line verdict plus the exact fix command. Use whenever aon join reports "NATS handshake failed", a role hits "Authorization Violation", or a joiner can't connect after the operator side appears healthy. Trigger phrases include "NATS handshake failed", "Authorization Violation", "joiner can't connect", "aon join failing", "diagnose NATS".
---

# aon: diagnose NATS handshake failure

Operator-side diagnostic. Inputs: the failing role name (`<role>`)
and the URL the joiner is using (`<url>`).

Walk these four checks **in order** and stop at the first failure.

## 1. Is the NATS container running?

```bash
docker compose -f ~/Repos/<team>-aon/docker-compose.yml ps nats
```

- **Stopped** → `docker compose -f ~/Repos/<team>-aon/docker-compose.yml up -d nats`. Done.
- **Up (unhealthy)** → check `aon nats logs` for crash loop. Often
  fixed by `aon nats up` (restart).
- **Up (healthy)** → continue to (2).

## 2. Is the role in the live auth.conf?

```bash
grep "user: <role>" ~/Repos/<team>-aon/nats/auth.conf
```

- **No match** → role missing from auth. Run `/aon:add-role` from
  scratch, or:
  ```bash
  cd ~/Repos/<team>-aon
  aon auth render && aon auth set-passwords && aon nats up
  ```
- **Match** → continue to (3).

## 3. Does the local server accept the role's password?

```bash
PW=$(grep '^<ROLE_UPPER>=' ~/Repos/<team>-aon/nats/.passwords | cut -d= -f2-)
NATS_PASSWORD="$PW" nats --server nats://localhost:4222 \
  --user <role> --timeout 5s server check connection
```

- **"Authorization Violation"** → server has stale auth. Server
  was running before the last `aon auth set-passwords`. Fix:
  ```bash
  docker compose -f ~/Repos/<team>-aon/docker-compose.yml restart nats
  ```
  Then re-run check (3). Should print `OK Connection OK`.
- **"connection refused"** → port 4222 not exposed (rare on local
  loopback). Verify `docker compose ps nats` again.
- **OK** → continue to (4). Local path is healthy; problem is
  remote-side.

## 4. Can the joiner reach the tunnel + auth?

Three sub-cases.

### 4a. Scheme typo

The joiner must use `wss://...`, NOT `https://`. nats CLI doesn't
speak HTTP. Confirm what they entered at the prompt. Fix:
```bash
rm ~/.team-alpha/<role>.env
aon join <role> <work-repo>
# at prompt: wss://<host>
```

### 4b. Stale URL

Joiner's `aon.toml` (cloned from team repo) has the old tunnel URL.
cloudflared restarted → URL rotated. Run `/aon:rotate-tunnel` to
patch + push the new URL, then tell joiner to:
```bash
cd ~/Repos/<team>-aon && git pull
rm ~/.team-alpha/<role>.env
aon join <role> <work-repo>
```

### 4c. Password mismatch on joiner's box

```bash
# operator side
diff <(printf '%s' "$(cat ~/.team-alpha/<role>.password)") \
     <(grep '^<ROLE_UPPER>=' ~/Repos/<team>-aon/nats/.passwords | cut -d= -f2-)
```

- Empty diff (or just trailing-newline) → operator-side file matches.
  Joiner's file is wrong. Re-send the password content out-of-band.
- Diff non-empty → re-run `aon creds <role>` operator-side, then
  re-send.

## Verdict template

After diagnosis, output one line:

> `<role>` failed at step `<N>` (<reason>). Fix: `<one command>`.

Examples:

> `vahid` failed at step 3 (server stale auth). Fix:
> `docker compose -f ~/Repos/team-poc-aon/docker-compose.yml restart nats`.

> `mihai` failed at step 4a (scheme typo). Fix: re-run `aon join`
> entering `wss://...` not `https://`.
