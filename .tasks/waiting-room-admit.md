---
column: Backlog
created: 2026-04-28
updated: 2026-04-28
order: 50
priority: high
blocks: streamline-aon-join (#12)
depends_on: nsc-jwt-migration
parent: onboarding-overhaul
---

# Waiting-room admit — human-gated joiner onboarding

Replace pre-shared password / `aon join-link TOKEN BITS` flow with a
NATS waiting-room subject that admin human approves live, after
verifying joiner identity out-of-band.

## Why

Current pain (per `streamline-aon-join`):

- Admin must run `aon onboard <role>` per joiner before sharing token.
- Token + bits shared out-of-band (Slack/email) — leak risk.
- Joiner box must paste long string. Easy to mistype.
- Role pre-bound to token — if admin picks wrong role, redo from scratch.

Waiting-room flips it: **admin does nothing per joiner upfront**. Joiner
shows up, admin approves live, creds minted at admit time.

## End state

```bash
# admin one-time team setup (unchanged)
aon init && aon add-role mihai && aon add-role vahid && aon nats up

# admin shares team URL (only thing out-of-band)
"team url: wss://abc-def-ghi-jkl.example.com"

# joiner box (sara's laptop)
aon connect wss://abc-def-ghi-jkl.example.com
# → publishes request, waits

# admin box
aon admit
# TUI shows: "sara@laptop-42 wants role vahid (fingerprint ab12...)"
# admin pings sara on slack: "fingerprint ab12?" sara: "yes"
# admin picks role, hits approve
# creds minted, encrypted to sara's pubkey, published

# sara's box decrypts, writes creds, joins NATS, done.
claude
```

## Flow detail

1. **Joiner box**: `aon connect <url>`
   - Generate ephemeral keypair (X25519 for cred encryption).
   - Publish to `team.<team>.waiting-room` with payload:
     ```json
     {
       "box_id": "<uuid>",
       "hostname": "<gethostname>",
       "user": "<whoami>",
       "requested_role": "<optional>",
       "joiner_pubkey": "<base64>",
       "fingerprint": "<short hash of pubkey>",
       "ts": "<iso>"
     }
     ```
   - Subscribe `team.<team>.waiting-room.<box_id>.reply` (ephemeral).
   - Print fingerprint to stdout: "share this with admin: `ab12...`".
   - Block until reply arrives or timeout (5 min default).

2. **Admin box**: `aon admit` (TUI)
   - Subscribe `team.<team>.waiting-room`.
   - List pending requests with: hostname, user, requested role,
     fingerprint, age.
   - Admin selects request → out-of-band confirms with joiner human.
   - Admin picks role from roster (defaulted to requested if any).
   - aon mints password (or NSC user JWT post-migration), encrypts to
     `joiner_pubkey` using X25519+ChaCha20-Poly1305 (libsodium box).
   - Publishes encrypted blob to reply subject.
   - Optionally records admit event to local audit log.

3. **Joiner box** (continued)
   - Decrypts blob with ephemeral private key.
   - Writes `~/.aon/teams/<team>/creds/<role>.password` (chmod 600).
   - Writes `<role>.env` with NATS URL.
   - Probes NATS handshake. ✓ done.
   - Prints welcome card (see streamline #10).

## ACL design

NATS account needs:

- **anon (or shared) publish** on `team.<team>.waiting-room` — joiners
  can publish even before they have creds. Subject-scoped: NO other
  publish allowed for this account.
- **anon subscribe** on `team.<team>.waiting-room.*.reply` — joiners
  receive their reply only (filter by their box_id).
- **admin user** subscribe on `team.<team>.waiting-room`,
  publish on `team.<team>.waiting-room.*.reply`.

Anon account = bootstrap only. Once admitted, joiner uses real per-role
creds for all team subjects.

## Crypto

- **Why encrypt the reply?** ACLs alone don't stop a malicious admin
  account or an admin operator on the wire from seeing creds. (NATS
  publishes are visible to anyone subbed to reply subject; box_id is in
  the request, not secret.)
- **Choice**: libsodium `crypto_box` (X25519 + XSalsa20-Poly1305).
  Joiner generates keypair per-request, ephemeral. Admin reads pubkey
  from request, seals reply.
- Python: `pynacl` available, well-tested. Add as engine dep.
- Fingerprint: `base32(sha256(pubkey))[:8]` — 8 chars human-readable
  for out-of-band confirm.

## Spam / abuse

URL leak → anyone can flood waiting-room. Mitigations:

- Admin TUI shows only N most recent requests (configurable).
- Per-source-IP rate limit at NATS layer (leaf node config or
  `max_connections` on anon account).
- Admin can `aon admit --reject <box_id>` to clear noise.
- (Optional) require a low-effort PoW or shared invite-code in the
  request payload — not a secret, just enough to stop drive-by spam.
  Defer to v2 if real abuse seen.

## Phase 1 (v1) — DECISIONS LOCKED 2026-04-28

Phase 2 deferred (TUI, JetStream audit, automated spam guards,
multi-admin quorum). Ship CLI-only v1 first; iterate on real
usage.

### Phase 1 scope decisions

1. **Bootstrap creds delivery**: NATS `no_auth_user: anon`
   directive in `nats-server.conf`. Add an `anon` user under the
   team account in NSC with strict ACL (publish on
   `team.<team>.waiting-room` and subscribe on
   `team.<team>.waiting-room.<box_id>.reply` ONLY). Joiner box
   connects without `--creds`; NATS maps unauth → anon user; ACL
   gates everything. No public creds file to ship, no separate
   anon account to design — single-account, one extra user.

   Rationale: simplest correct approach. Cross-account complexity
   (exports/imports) avoided. ACL is the security boundary.

2. **Admin UX**: CLI only for v1. Two subcommands:
   - `aon admit list` — show pending requests
   - `aon admit approve <box_id> [role]` — encrypt + publish reply
   - `aon admit reject <box_id>` — clear noise
   No TUI. Plain output, scriptable. TUI = Phase 2.

3. **Audit trail**: append-only file on admin box at
   `~/.aon/teams/<team>/admits.log`. JSON-lines. JetStream
   audit-subject = Phase 2.

4. **Role conflicts**: admin TUI/CLI shows existing admits per
   role. Refuse double-admit unless `--force-replace` flag.
   v1: simple file-based check against `admits.log`. Phase 2 may
   move to KV / JS.

5. **Revocation**: covered by `nsc-jwt-migration` (✅ done).
   `aon revoke <role>` works; no re-admit needed for revoke flow.

6. **Fingerprint UX**: 8 chars (40 bits, base32 of sha256 of
   pubkey first 5 bytes). 5min default request TTL. Acceptable
   for v1.

### Phase 1 crypto + lang choice

`aon` is bash. Crypto in bash = pain. Decision: ship a small
Python helper at `scripts/aon-crypto/box.py` with two
subcommands:

- `box.py encrypt --pubkey <base64> --in <jwt-blob>` →
  base64-encoded ciphertext on stdout
- `box.py decrypt --privkey <base64> --in <ciphertext-base64>` →
  jwt blob on stdout
- `box.py keypair` → `{pub, priv}` json on stdout

Uses `pynacl`. Add to engine `pyproject.toml` (engine has Python
already for `mcp-server`). `aon` shells out to it.

### Phase 1 NATS account/user shape

```
operator: aon-op (existing)
account:  team-<name> (existing)
   users:
     sysadmin
     <role> per aon.toml roster (existing)
     anon (NEW)
        --allow-pub  team.<team>.waiting-room
        --allow-sub  team.<team>.waiting-room.*.reply
        --deny-pub   >
        --deny-sub   > (except the explicit allows above)
```

`nats-server.conf` adds:

```
no_auth_user: anon
```

Joiner connects without `--creds`. Server maps to anon. ACL
locks them to waiting-room subjects only.

### Phase 1 message shapes

Joiner publishes (to `team.<team>.waiting-room`):

```json
{
  "v": 1,
  "box_id": "<uuid>",
  "hostname": "<gethostname>",
  "user": "<whoami>",
  "requested_role": "<optional>",
  "joiner_pubkey": "<base64-X25519>",
  "fingerprint": "<base32-8chars>",
  "ts": "<iso>"
}
```

Admin replies (to `team.<team>.waiting-room.<box_id>.reply`):

```json
{
  "v": 1,
  "ok": true,
  "role": "<assigned-role>",
  "ciphertext": "<base64 libsodium-box(creds_blob)>",
  "ts": "<iso>"
}
```

Or on reject:

```json
{ "v": 1, "ok": false, "reason": "<why>" }
```

### Phase 1 implementation order

1. **NSC anon user template** (`templates/auth/anon.tmpl` +
   `_aon_nsc_ensure_user` kind=anon dispatch). Smoke against
   nsc-smoke fixture.
2. **`nats-server.conf` template**: add `no_auth_user: anon`.
   `aon auth render` mints anon user along with roster.
3. **`scripts/aon-crypto/box.py`**: pynacl wrapper. Add pynacl
   to engine `pyproject.toml`. Smoke (encrypt-then-decrypt).
4. **`aon connect <url>`** (`cmd_connect` in bin/aon):
   - generate ephemeral keypair via box.py
   - resolve URL to NATS endpoint (parse wss → nats)
   - connect anon (no creds), publish waiting-room request,
     sub reply, block 5min default
   - on reply: decrypt creds, write
     `~/.aon/teams/<team>/creds/<role>.creds` chmod 600,
     write `<role>.env`, register work-repo, probe handshake,
     print welcome card
5. **`aon admit list`** (`cmd_admit_list`):
   - sub `team.<team>.waiting-room`, drain pending,
     print box_id + hostname + user + requested_role +
     fingerprint + age. Cross-check against `admits.log` for
     dup detection display.
6. **`aon admit approve <box_id> [role] [--force-replace]`**
   (`cmd_admit_approve`):
   - look up box_id from cached pending list (or re-fetch)
   - if role unset, use requested_role
   - check `admits.log` for prior admit on this role; refuse
     unless `--force-replace`
   - mint per-role JWT via NSC (`aon creds <role>`)
   - read `<role>.creds` content
   - encrypt to joiner_pubkey via box.py
   - publish reply on `team.<team>.waiting-room.<box_id>.reply`
   - append admit event to `~/.aon/teams/<team>/admits.log`
7. **`aon admit reject <box_id> [reason]`**:
   - publish `{ok: false, reason}` to reply subject
   - log to `admits.log`
8. **Smoke test** at `scripts/nsc-smoke/run-smoke.sh` Phase F:
   anon user can publish waiting-room, can't publish elsewhere
   (forge), admin sees, approves, joiner receives + decrypts +
   handshakes, total round-trip < 10s in fixture.
9. **`aon join-link` deprecation warning**: print
   "deprecated, use `aon connect <url>`" but keep working.
   Remove after waiting-room proven in real use.
10. **Doc**: README + `docs/runbooks/waiting-room-admit.md`
    walkthrough mirroring the nsc-rotate-user runbook style.

## Dependencies

- **Should land after NSC migration** (`nsc-jwt-migration` card) so
  creds = signed user JWT, not raw password. Encrypting a JWT is
  cleaner; revocation works.
- Independent of streamline-aon-join sub-tasks #1–#12, but supersedes
  the `aon join-link` flow once shipped.

## Acceptance

- Admin runs `aon init` once + shares team URL. No per-joiner steps.
- Joiner runs `aon connect <url>` only. No token paste, no role flag.
- Admin approves via `aon admit` after out-of-band identity check.
- Creds delivered encrypted; never visible in plaintext on the wire.
- Spam from a leaked URL doesn't lock out legit joiners.
- Audit log records every admit (who, when, role, fingerprint).

## Out of scope

- NSC/JWT migration itself (`nsc-jwt-migration` card).
- Multi-admin quorum approval (just one admin per request for v1).
- Auto-admit / pre-shared invite codes (could be v2 if pure-manual
  approval too slow).
- Joiner box re-attestation after reboot (creds persist, no re-admit
  needed).

## Order to do

See "Phase 1 implementation order" section above (steps 1-10).
Phase 2 deferred until v1 in real use.

## Phase 2 deferred (DO NOT IMPLEMENT YET)

Defer until pain shows up in v1 daily use:

- **TUI** (`aon admit` interactive picker via bubbletea or
  similar). v1 CLI is enough for 2-person team.
- **JetStream audit subject** `team.<team>.audit.admits`. v1
  file audit covers single-admin case.
- **Spam guards**: per-IP rate limit at NATS layer, max-pending
  cutoff in TUI display, optional PoW. v1 manual `aon admit
  reject` handles small-scale noise.
- **Multi-admin quorum approval** (>1 admin signs an admit).
- **Auto-admit / pre-shared invite codes** (could replace manual
  approval if it becomes a bottleneck).
