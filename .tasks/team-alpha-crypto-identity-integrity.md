---
column: Backlog
created: 2026-04-27
order: 990
priority: deferred
parent: true
---

# Cryptographic identity + integrity (single Ed25519 key)

Parent card grouping the two-step migration that gives team-alpha both
**connection-level identity** (per-role auth) and **per-message identity
+ integrity** (signed envelopes), backed by a **single Ed25519 keypair
per role**.

Supersedes the symmetric-secret HMAC MVP
(`team-alpha-hmac-payload-signing.md`) once both subcards land. HMAC
stays as the MVP rung — when Sub B ships strict-ed25519, HMAC verifier is
removed in a cleanup slice.

## Why one parent

The two subcards used to be independent (`nsc-jwt-migration.md`,
`team-alpha-ed25519-payload-signing.md`). They are not. The point of
doing JWT migration **first** is so the nkey seed it produces becomes
the **same key** Ed25519 signing uses. One keypair per role. One
distribution path (`.creds`). One rotation (`nsc edit user` + republish
pubkey). One revocation (`nsc revocations`). No parallel keystores.

If we landed Ed25519 standalone first (option B from the planning
discussion), we'd carry two keystores during the transition window and
have to retrofit the seed source later. Parent card commits to A (do
JWT first, signing piggybacks).

## Subcards

Build in order. Sub B blocks on Sub A.

### Sub A — NSC/JWT decentralized auth ([`nsc-jwt-migration.md`](nsc-jwt-migration.md))

Replace static `accounts {}` / `users {}` block in `nats-server.conf`
with operator-signed JWT auth via `nsc`. Per-role `.creds` files. Key
material: each role's nkey seed (Ed25519). Rotation, revocation, public
internet exposure all enabled by this rung.

**Key takeaway for Sub B**: `nsc add user <role>` produces an Ed25519
**nkey seed** stored in the role's `.creds` file. That seed IS the
private key Sub B will sign with — no separate generation, no second
keystore.

### Sub B — Ed25519 envelope signing ([`team-alpha-ed25519-payload-signing.md`](team-alpha-ed25519-payload-signing.md))

`crypto.py` v2: replace HMAC envelope with Ed25519 per-role signing.
Private key derived from the role's nkey seed (output of Sub A).
Public key map distributed via `agents/<role>.json` `pubkey` field.
Verifier accepts both v1 (HMAC) and v2 (Ed25519) during transition;
flips to v2-only after `strict-ed25519` rolls out cluster-wide.

## Trigger to start (parent gate)

Pick this up when any of these fire (same trigger list as Sub A):

- Adding a second team / account boundary needed.
- Need credential rotation without server restart.
- Need revocation of a single user without redistributing `auth.conf`.
- Exposing NATS to public internet (per-user signed creds > shared
  password file).
- Need per-message non-repudiation (Sub B becomes urgent when threat
  model includes a malicious or compromised role attempting to forge
  envelopes as another role — HMAC cannot catch this).

## Migration sequence

1. **HMAC ships** (current state — `team-alpha-hmac-payload-signing.md`
   slices S1+S2+S3 done). Provides tamper evidence + replay protection
   while parent stays deferred.
2. **Sub A: NSC/JWT lands.** `.creds` files distributed; `nats-server.conf`
   switches to operator + resolver. Old user/password block removed.
   Cluster routes still green.
3. **Sub B: Ed25519 signing lands.**
   - `aon sig genkey`: read role's nkey seed from `.creds`, derive
     Ed25519 keypair, write pubkey hex to `agents/<role>.json`.
   - PR pubkey additions; cluster reloads pubkey map (SIGHUP or restart).
   - Flip `TEAM_ALPHA_SIG_MODE=warn-ed25519`; soak; flip
     `strict-ed25519`.
4. **Cleanup slice**: drop HMAC verifier, collapse mode env to
   `{off, warn, strict}`, retire `cluster.hmac` + `aon hmac`
   subcommand.

## Parent acceptance (rolls up subcards)

- [ ] Sub A acceptance criteria all green (six users on `.creds`,
      revocation works without restart, perms preserved).
- [ ] Sub B acceptance criteria all green (forge test catches
      cross-role spoof, perf <2ms p99, rotation works within retention
      window).
- [ ] **Single key per role.** No role has both an nkey seed and a
      separate Ed25519 keystore. `aon sig genkey` derives from
      `.creds`, full stop.
- [ ] HMAC verifier + `cluster.hmac` removed in cleanup slice.
- [ ] `MODEL.md` updated: identity now = `.creds` (connect) +
      Ed25519 envelope (per-message). HMAC mentioned only as
      historical MVP.

## Non-goals (parent-level)

- Multi-operator federation (would need a CA or SPIFFE — separate ADR).
- Encrypting payloads at rest (TLS covers transit; storage encryption
  orthogonal).
- Layered HMAC + Ed25519 ("defense in depth"). Ed25519 alone covers
  tamper + identity. Layering doubles key management with no offsetting
  gain.

## References

- [team-alpha-hmac-payload-signing.md](team-alpha-hmac-payload-signing.md)
  — MVP rung this parent supersedes.
- [nsc-jwt-migration.md](nsc-jwt-migration.md) — Sub A.
- [team-alpha-ed25519-payload-signing.md](team-alpha-ed25519-payload-signing.md)
  — Sub B.
- [MODEL.md](../MODEL.md) — permission contracts JWT claims must preserve.
- Ed25519 RFC 8032: https://datatracker.ietf.org/doc/html/rfc8032
- NATS NSC docs: https://docs.nats.io/running-a-nats-service/configuration/securing_nats/auth_intro/jwt
