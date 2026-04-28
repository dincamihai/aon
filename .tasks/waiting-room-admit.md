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

## Open questions

1. **Bootstrap creds delivery**: anon NATS account credentials
   themselves — how does joiner box get them? Options:
   - Bake into engine binary (publicly known, ACL-scoped to
     waiting-room only — fine if ACL airtight).
   - Operator publishes a `bootstrap.creds` file alongside team URL.
   - Ship anon JWT signed by team account (post-NSC).
   Probably (a) for simplicity once NSC migration done.

2. **Admin UX**: TUI vs CLI? `aon admit` interactive picker, or
   `aon admit list` + `aon admit approve <box_id> <role>`? Probably
   both — list/approve for scripting, TUI for humans.

3. **Audit trail**: where to log admits? `~/.aon/teams/<team>/admits.log`
   on admin box, or publish to a `team.<team>.audit.admits` JetStream
   subject for durability? Probably both.

4. **Role conflicts**: admin admits sara as `vahid`, but mihai already
   admitted as `vahid` from earlier. Detect: aon checks per-role admit
   state in audit stream before minting. Refuse if double-admit unless
   `--force-replace`.

5. **Revocation**: how to kick admitted box later? Out of scope here —
   covered by NSC migration (revoke JWT). Pre-NSC: rotate password +
   re-admit only intended boxes.

6. **Fingerprint UX**: 8 chars enough for out-of-band confirm? Probably.
   2^40 collision space, attacker would need to race + grind keypair to
   match — within a 5-min window not realistic.

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

1. Design ACL for anon waiting-room account; test in local NATS.
2. Wire `aon connect` (joiner side): keypair, publish, wait, decrypt.
3. Wire `aon admit list` + `aon admit approve` (CLI first).
4. Add `pynacl` dep; libsodium box round-trip.
5. Audit log (local file + optional JetStream).
6. TUI on top of CLI.
7. Spam guards (rate limit, max pending).
8. Migrate `aon join-link` to deprecation warning, remove after one
   release cycle.
