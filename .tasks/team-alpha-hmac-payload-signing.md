---
column: In-Progress
created: 2026-04-27
order: 1010
priority: medium
---

# HMAC payload signing for tamper evidence on relayed messages

Implementable **now** — no NSC/JWT dependency. Reuses existing creds-file
distribution pattern. Refactor when JWT lands (~30 LOC, swap key source
from local file to nkey seed).

**Superseded path**: see parent
[`team-alpha-crypto-identity-integrity.md`](team-alpha-crypto-identity-integrity.md).
HMAC is the MVP rung; Sub A (NSC/JWT) + Sub B (Ed25519 signing) replace
it. HMAC verifier removed in cleanup slice once `strict-ed25519` is
soaked.

## Problem

Current ai-over-nats trust model stops at NATS subject ACL. Payload integrity
not verified end-to-end:

- Identity fields (`by`, `from_role`) inside JSON payloads are trust-based.
  Subject routing gates publish, so direct spoof on own subject is bounded —
  but **relayed messages** (bouncer, coordinator forwards, audit replays,
  cross-account bridges) lose that binding once payload hops servers.
- No tamper evidence on persisted JetStream messages. Operator with stream
  write access could rewrite history without detection.
- No replay protection on stored events.

## Now-path implementation

Shared cluster HMAC secret (single key, all roles hold it). Sign envelope
on publish, verify on receive. Focus = tamper evidence + replay block on
relayed/persisted messages, not asymmetric identity proof. (For per-role
identity proof switch to Ed25519 post-JWT migration — separate slice.)

### Slices

**S1 — crypto core (this card)**

1. `mcp-server/.../crypto.py`:
   - `sign_envelope(payload: dict, role: str) -> dict` — wraps payload as
     `{v:1, by, ts, nonce, payload, sig}` with HMAC-SHA256 over canonical
     JSON.
   - `verify_envelope(env: dict, *, expected_role=None, replay_window=300)
     -> dict` — returns inner payload or raises `SignatureError` /
     `ReplayError` / `StaleError`.
   - Bounded replay cache (LRU 10k nonces) for `seen` detection.
   - Key source: `TEAM_ALPHA_HMAC_KEY` env (raw) or
     `TEAM_ALPHA_HMAC_KEY_FILE` (default `~/.team-alpha/cluster.hmac`,
     chmod 600).
   - Mode env `TEAM_ALPHA_HMAC_MODE` ∈ {off (default), warn, strict}.
2. `crypto.py` tests:
   - sign+verify roundtrip.
   - tamper byte → `SignatureError`.
   - replay same nonce → `ReplayError`.
   - stale ts beyond window → `StaleError`.
   - missing sig under `strict` → reject; under `warn` → log + pass.
   - wrong role claim → `SignatureError` (sig binds role).
3. `event_payload()` opt-in wrap when mode != off.
4. Doc: README section "Tamper evidence (HMAC)" with rollout steps.

**S2 — wire receivers (separate card)**

5. Worker accept loop (`a2a/worker.py`) verifies inbound `tasks/send`.
6. Dispatcher verifies `tasks/*/status` on continuity-bias lookup.
7. DM inbox verifies sender.
8. Replay-cache survives reconnect via KV?

**S3 — rollout plumbing (this card, done)**

9. `aon hmac genkey|status|mode` subcommand → `~/.team-alpha/cluster.hmac`,
   `~/.team-alpha/hmac.mode`.
10. `aon launch`, `aon monitor`, `aon join` export
    `TEAM_ALPHA_HMAC_KEY_FILE` + `TEAM_ALPHA_HMAC_MODE` from the persisted
    state. Joiner defaults to `warn` once a key exists.
11. `.mcp.json` env block + hooks env-prefix include both vars.
12. `docs/hmac-runbook.md` covers rollout (off→warn→strict), rotation,
    troubleshooting.

**S4 — operational rollout (manual; not code)**

13. Operator runs `aon hmac genkey`; distributes `cluster.hmac` to all
    role hosts.
14. `aon hmac mode warn`; restart roles; soak ≥48h watching for
    `unsigned message accepted` log lines.
15. `aon hmac mode strict`; restart roles; verify with tamper + replay
    tests against AUDIT.

## Acceptance (S1+S2+S3)

- [ ] `crypto.py` ships with sign/verify + replay cache.
- [ ] All tests pass: roundtrip, tamper, replay, stale, missing sig modes,
      role claim mismatch.
- [ ] `event_payload()` wraps under `TEAM_ALPHA_HMAC_MODE in {warn, strict}`.
- [ ] `mode=off` is default → zero behavior change for existing deployment.
- [ ] Perf: <1ms sign+verify p99 for typical 1KB payload.
- [ ] No new external deps (stdlib `hmac`, `hashlib`, `secrets` only).

## Tradeoffs

- **Pro**: ships in days; hardens MVP before bouncer/JWT.
- **Pro**: tamper/replay tests usable immediately on AUDIT-stored events.
- **Con**: shared cluster secret = tamper evidence vs operators/relays only,
  not per-role forgery proof (any role holding key could forge). Acceptable
  for relay-tamper threat; strict role-identity proof = post-JWT Ed25519.
- **Con**: key distribution still manual (same channel as passwords).
- **Con**: rotation = redistribute file + restart agents (no live revoke).

## Non-goals

- Per-role asymmetric identity proof (Ed25519, post-JWT).
- Encrypting payloads (TLS covers transit; JetStream encryption separate).
- Signing KV writes (KV ACL covers).

## References

- [MODEL.md](../MODEL.md) — current trust layers (subject ACL strong,
  payload trust-based).
- [nsc-jwt-migration.md](nsc-jwt-migration.md) — when JWT lands, swap key
  source to nkey seed; consider Ed25519 upgrade slice.
- [team-alpha-a2a-investigation.md](team-alpha-a2a-investigation.md) §5c —
  bouncer service consumes signed envelopes once shipped.
