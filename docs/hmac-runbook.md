# HMAC payload signing — rollout & rotation runbook

ai-over-nats supports tamper-evident payloads via HMAC-SHA256 envelopes
keyed by a shared cluster secret (`~/.team-alpha/cluster.hmac`). Threat
model: relay/operator tampering of payloads after publish, replay of
stored events. Per-role identity proof requires post-JWT Ed25519
(out of scope here).

See: [`team-alpha-hmac-payload-signing.md`](../.tasks/team-alpha-hmac-payload-signing.md).

## Modes

| mode   | publishers           | consumers                                  |
|--------|----------------------|--------------------------------------------|
| off    | unsigned (default)   | accept all (no verification)               |
| warn   | sign envelope        | verify if signed; accept unsigned + log    |
| strict | sign envelope        | reject unsigned, bad-sig, stale, replayed  |

Env vars (read at MCP server startup; restart role to pick up):

- `TEAM_ALPHA_HMAC_MODE` ∈ {off, warn, strict}; default `off`.
- `TEAM_ALPHA_HMAC_KEY_FILE` — path to shared secret (default
  `~/.team-alpha/cluster.hmac`).
- `TEAM_ALPHA_HMAC_KEY` — raw inline key (overrides file).

## Rollout (off → warn → strict)

1. **Generate secret** (operator host):
   ```
   aon hmac genkey
   ```
   Writes `~/.team-alpha/cluster.hmac` (32B hex, chmod 600).

2. **Distribute identical file** to every role's host. Same channel as
   role passwords (out-of-band; gitignored). All roles must hold the same
   bytes.

3. **Flip mode to warn**:
   ```
   aon hmac mode warn
   ```
   `aon launch` and `aon join` now export `TEAM_ALPHA_HMAC_MODE=warn`
   plus the key file path. Restart all role MCP servers (relaunch claude
   or kill/restart the stdio MCP process).

   New `aon join` runs auto-default to `warn` once a key exists.

4. **Soak**. Publishers sign, consumers verify-when-possible. Watch logs
   for `unsigned message accepted (mode=warn)` — each occurrence is an
   un-upgraded publisher. Patch until clean for ≥48h.

5. **Flip to strict**:
   ```
   aon hmac mode strict
   ```
   Restart all roles. Unsigned/bad-sig/stale/replayed messages now
   rejected with `crypto: …` errors.

6. **Verify**:
   - Smoke tests pass.
   - Tamper test: replay a stored AUDIT event with one byte flipped via
     `nats pub` — receiver should reject (look for `signature mismatch`
     in logs).
   - Replay test: re-publish an unmodified stored event from outside the
     replay window (default 300s) — receiver should reject with
     `ts … outside replay window`.

## Rotation

When to rotate: suspected key leak, role offboarding, scheduled cycle
(every N months).

1. **Generate new key**:
   ```
   mv ~/.team-alpha/cluster.hmac ~/.team-alpha/cluster.hmac.old
   aon hmac genkey
   ```

2. **Drop to warn temporarily** (so old + new can coexist during
   distribution):
   ```
   aon hmac mode warn
   ```
   Restart roles host-by-host. Caveat: warn mode does not currently
   accept multiple keys in parallel; messages signed with the old key
   will fail-verify and be logged as "unsigned" only when the *consumer*
   has the new key. Plan a brief inconsistent window or rotate
   bottom-up (consumers first, publishers last) within a few minutes.

3. **Distribute new file** to all hosts.

4. **Flip back to strict** once all hosts have new key:
   ```
   aon hmac mode strict
   ```
   Delete `cluster.hmac.old` from all hosts.

5. **Audit**: replay any stored events signed with old key are now
   permanently unverifiable. Acceptable trade-off (they'd be flagged
   `_unverified` by the `recent_events` MCP tool).

## Disabling

Revert to `off` for debugging:
```
aon hmac mode off
```
Restart roles. Now-publishers stop signing; consumers accept all.

## Troubleshooting

- **`crypto: HMAC key file not found`** at server start → run
  `aon hmac genkey` (or copy the operator's key) and re-launch.
- **`unsigned message rejected in strict mode`** → publisher still on
  off/old build. Check that role's `TEAM_ALPHA_HMAC_MODE` env at
  process start.
- **`ts … outside replay window`** → clock skew. Sync NTP cluster-wide
  or relax `replay_window` (currently 300s, hardcoded).
- **`nonce … already seen`** → genuine replay, or the publisher
  republished the same envelope. The replay cache is per-process;
  restarts reset it. Cross-process dedup = follow-up slice (KV-backed).

## File locations

| path                              | purpose                          |
|-----------------------------------|----------------------------------|
| `~/.team-alpha/cluster.hmac`      | shared HMAC secret (chmod 600)   |
| `~/.team-alpha/hmac.mode`         | persisted mode (off/warn/strict) |
| `~/.team-alpha/<role>.env`        | sourced env file (mode + key)    |
| `<work-repo>/.mcp.json`           | MCP server env block             |
| `<work-repo>/.claude/settings.json` | hooks env-prefix                |
