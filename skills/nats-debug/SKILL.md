---
name: nats-debug
description: Debug NATS message delivery failures in aon teams. Use this skill when messages between agents don't arrive, DMs go missing, users report "X can't see Y's messages", publish violations appear, agents timeout waiting for replies, or after `aon admin reinit` or creds re-issue. Covers DM delivery debugging, JWT permission inspection, resolver cleanup, server restart, and end-to-end delivery testing.
---

# NATS Debug — aon team troubleshooting

## Symptom triage

Before diving deep, collect signals:

```
# 1. NATS server running?
pgrep -a nats-server

# 2. aon env healthy?
aon doctor 2>&1 | head -20

# 3. Server logs for publish violations
tail -100 /home/mihai/.aon/nats/nats-server.log 2>/dev/null | grep -i -E "violation|error|denied|reject|unauthorized|permission"
```

Three common symptom clusters:

| Symptom | Likely root | First action |
|---------|-------------|--------------|
| Publish Violation in logs | Stale account JWT or user JWT permissions | `aon admin reinit` |
| Silent drop (no violation, no delivery) | Wrong account/team, stale resolver, or wrong creds | Check resolver JWTs, verify creds match team |
| "X can't see Y's messages" but others work | Specific user JWT missing `agents.*.inbox` pub allow | Decode both user JWTs, compare pub/sub allow lists |

---

## Step 1 — Check for stale NATS processes

Stale monitors and old agent sessions are the #1 cause of "messages not arriving" after a reinit. NATS clients read creds once at connect time — they do NOT hot-reload when creds file changes on disk.

### Find zombie monitors

List all long-running `nats sub` processes:

```
ps aux | grep "nats.*sub" | grep -v grep
```

**What to check:**
- **Wrong subject patterns** — old monitors subscribe to `agents.rona.inbox` (missing `org.workers.` prefix), miss all current messages
- **Wrong team creds** — monitors using `~/.aon/teams/aon-workers/creds/` (old team name) vs `~/.aon/teams/workers/creds/` (current)
- **Multiple instances** — same role may have 2-3 monitors running from different sessions

### Count processes per role

```
ps aux | grep "role-monitor.sh" | grep -v grep | awk '{for(i=9;i<=NF;i++) printf "%s ", $i; print ""}' | sort | uniq -c | sort -rn
```

If a role has multiple monitors, only the most recent one matters — older ones use stale creds and stale subject patterns.

### Kill stale processes

```
# Kill all nats sub processes with old subject pattern (missing org.workers. prefix)
ps aux | grep "nats.*sub" | grep -v "org.workers" | grep -v grep | awk '{print $2}' | xargs -r kill

# Kill all monitors for an old/deprecated team
ps aux | grep "role-monitor.sh" | grep "aon-workers" | grep -v grep | awk '{print $2}' | xargs -r kill
```

After killing, each role needs exactly one active monitor. Restart any missing monitors.

### Why stale processes exist

The aon team uses `org.workers.*` subject hierarchy. Older monitors (before the rename) use `a2a.*` or `aon-workers.*` subjects. They connect to NATS but see nothing — creating false negatives during debugging.

### After reinit: existing sessions hold old creds

`aon admin reinit` re-mints creds on disk. But:
- Running monitors → stale JWT until they reconnect
- Running Claude Code sessions → stale MCP server connections
- Running `nats sub` processes (in monitors) → stale JWT until killed

**Fix:** bounce NATS server after reinit to force all clients to reconnect with fresh creds:

```
pkill nats-server
nats-server -c /home/mihai/.aon/nats/nats-server.conf &
```

Or kill and restart individual monitors for each role.

---

## Step 2 — Resolve environment

Always confirm which team and account you're debugging:

```
aon resolve-env
```

Key fields: `AON_TEAM`, `AON_ROSTER`, `AON_CREDS`. If roster missing expected roles, the team config is stale.

---

## Step 3 — Inspect account JWT

The account JWT in the resolver governs what the account allows. Decode it:

```
python3 -c "
import base64, json
with open('/home/mihai/.aon/nats/resolver/AA2K4W22Z7KYOQ5BAPBLEL6RMBAUBLX3V4EVDA4LAYKFASKFXGLSQZ5S.jwt') as f:
    jwt = f.read().strip()
payload = jwt.split('.')[1]
padding = 4 - len(payload) % 4
if padding != 4: payload += '=' * padding
d = json.loads(base64.urlsafe_b64decode(payload))
print(json.dumps(d, indent=2, sort_keys=True))
"
```

**What to check:**
- `name` field matches the team you expect (e.g. "workers")
- `default_permissions` — empty `{}` means no defaults, each user JWT must carry its own permissions
- `authorization` — empty `{}` means no auth groups (clean)
- `iat` (issued at) — should be recent if reinit was run

**To list ALL account JWTs in the resolver and their names:**

```
for f in /home/mihai/.aon/nats/resolver/*.jwt; do
    name=$(basename "$f")
    sub=$(cat "$f" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','?'))" 2>/dev/null)
    iat=$(cat "$f" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; import datetime; ts=json.load(sys.stdin).get('iat',0); print(datetime.datetime.fromtimestamp(ts).isoformat())" 2>/dev/null)
    echo "$f → $name | $iat"
done
```

---

## Step 4 — Inspect user JWTs

Decode a user JWT from its `.creds` file to check its pub/sub permissions:

```python
import base64, json
with open('/home/mihai/.aon/teams/workers/creds/<role>.creds') as f:
    lines = f.readlines()
in_jwt = False
for line in lines:
    line = line.strip()
    if 'BEGIN NATS USER JWT' in line:
        in_jwt = True; continue
    if 'END NATS USER JWT' in line:
        break
    if in_jwt and line:
        parts = line.split('.')
        payload = parts[1]
        padding = 4 - len(payload) % 4
        if padding != 4: payload += '=' * padding
        d = json.loads(base64.urlsafe_b64decode(payload))
        print(json.dumps(d['nats'], indent=2))
        break
```

**What to check:**
- `pub.allow` — must include `"org.workers.agents.*.inbox"` for cross-role DM
- `sub.allow` — must include `"org.workers.agents.<role>.inbox"` and `"_INBOX.>"`
- `iss` must match the account public key (the `sub` field of the account JWT)
- If a user JWT is missing permissions, their creds need re-issue

**Compare good vs bad pair.** If sun↔ari works but joana↔tim doesn't, decode all four. The broken pair likely missing `agents.*.inbox` in one direction.

---

## Step 5 — Fix ACL drift

If permissions are missing or stale, re-render auth:

```
echo y | aon admin reinit
```

This runs: `cmd_auth_render --apply-acl-drift` → `cmd_bootstrap` → `cmd_prompts_render`.

**Surgical re-issue for one role:**
```
aon admin reinit <role>
```

**NSC keystore note:** aon uses `~/.aon/nsc/data/nats/nsc/keys`, not default `~/.local/share/nats/nsc/keys`. If `nsc keys migrate` is needed:

```
nsc keys migrate --keystore-dir ~/.aon/nsc/data/nats/nsc/keys
```

After reinit, verify the resolver has the updated account JWT (check `iat` timestamp increased).

---

## Step 6 — Prune stale resolver JWTs

Old test-team account JWTs in the resolver cause confusion but don't interfere with delivery (each account is independent). Clean them up to reduce noise:

```
# Keep only current team account + SYS
cd /home/mihai/.aon/nats/resolver
for f in *.jwt; do
    name=$(cat "$f" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','?'))" 2>/dev/null)
    case "$name" in
        workers|SYS|your-team-name) echo "KEEP $f → $name" ;;
        *) rm -v "$f" ;;
    esac
done
```

---

## Step 7 — End-to-end DM delivery test

Test actual message delivery as specific users:

```
# Subscribe as recipient (background, timeout 5s)
timeout 5 nats sub --creds /home/mihai/.aon/teams/workers/creds/<recipient>.creds \
  "org.workers.agents.<recipient>.inbox" --count=1 2>/dev/null &

sleep 0.5

# Publish as sender
nats pub --creds /home/mihai/.aon/teams/workers/creds/<sender>.creds \
  "org.workers.agents.<recipient>.inbox" \
  '{"from":"<sender>","to":"<recipient>","test":"DM-check","ts":"2026-01-01T00:00:00Z"}'

wait
```

If the message appears on the subscriber, NATS delivery works — the issue is on the agent side (not subscribed, wrong subject pattern, stale connection).

**Test all quadrants:**
- joana → tim and tim → joana
- generalist → manager and manager → generalist
- specialist → generalist

---

## Step 8 — Server restart

If server is down or config changed:

```
# Kill existing
pkill nats-server

# Restart
nats-server -c /home/mihai/.aon/nats/nats-server.conf &
```

After restart, the resolver reloads account JWTs from disk. Verify with `pgrep -a nats-server`.

---

## Step 9 — Verify broadcast permissions

Broadcasts use a different subject pattern. Only managers can publish to `org.workers.broadcast.team`. Non-managers get Publish Violation — this is expected.

Check who can publish to broadcast:
- `org.workers.broadcast.team` — manager only (by design, enforced in ACL)
- `org.workers.broadcast.incidents` — all roles
- `org.workers.broadcast.test` — all roles

If a manager gets broadcast violations, their user JWT's `pub.allow` might be missing the subject.

---

## Quick reference — important paths

| What | Path |
|------|------|
| NATS server config | `~/.aon/nats/nats-server.conf` |
| NATS server log | `~/.aon/nats/nats-server.log` |
| Resolver JWTs | `~/.aon/nats/resolver/` |
| Team creds | `~/.aon/teams/<team>/creds/<role>.creds` |
| NSC keystore | `~/.aon/nsc/data/nats/nsc/keys` |
| Team local config | `~/.aon/teams/<team>/aon-local.toml` |

## Quick reference — key NATS subjects

| Subject | Purpose |
|---------|---------|
| `org.workers.agents.<role>.inbox` | DM inbox for each role (pub/sub per-role) |
| `org.workers.agents.*.inbox` | Wildcard to publish to any role's inbox |
| `org.workers.broadcast.team` | Manager-only team broadcast |
| `org.workers.broadcast.incidents` | Incident alerts (all roles) |
| `org.workers.a2a.<role>.tasks.>` | A2A task lifecycle |
| `_INBOX.>` | NATS request-reply inboxes |
