---
column: Backlog
created: 2026-05-14
order: 171
---

## Status: Postponed — blocked on card 169 (HTTP+SSE bridge)

Auth field doesn't exist in actual `agents/*.json` today (only in
Python generator; Rust `aon-card` has no auth field at all). Zero
code reads or verifies it. No consumer until external agents need to
verify identity via the HTTP bridge.

NSC JWT already handles connection auth (`.creds` files). This card
just adds operator/account NKey fingerprints to the card metadata so
external agents can cryptographically verify "this card was issued by
operator X" — only relevant when card 169 ships.

Unblock when: `team-alpha-a2a-http-sse-bridge.md` (169) is taken off
the shelf.

---

# A2A JWT auth migration

Current agent cards (`agents/<role>.json`) declare
`"auth": {"scheme": "nats-user"}` — a placeholder. The A2A spec
and external interop require a proper auth scheme. NATS already
uses NKey + JWT credentials; this card wires that identity into
the A2A card surface and external-facing endpoints.

Referenced as "card 70" in `aon-card/src/main.rs` comments.

## Deliverables

### 1. Card auth field

Update `AgentCard` struct in `aon-card/src/main.rs` and
`scripts/gen-agent-cards.py` to populate:
```json
"auth": {
  "scheme": "nats-jwt",
  "issuer": "<operator-public-nkey>",
  "audience": "<account-public-nkey>"
}
```
Values read from `nsc describe operator` + `nsc describe account`
at card generation time. Fall back to `"nats-user"` when nsc
unavailable (local dev without NSC).

### 2. `aon-card gen` update

`aon-card/src/main.rs gen` subcommand reads operator/account NKeys
from environment (`NSC_OPERATOR_KEY`, `NSC_ACCOUNT_KEY`) or from
`~/.nsc` store and populates the `auth` block.

### 3. Verification in `get_peer_cards()`

`__main__.py:get_peer_cards()` optionally verifies the `issuer`
field matches the configured operator NKey (`AON_OPERATOR_NKEY` env).
Log a warning (not error) when mismatch — allows cross-operator
federation without hard failure.

### 4. HTTP+SSE bridge integration

When `team-alpha-a2a-http-sse-bridge.md` (card 169) is implemented,
bearer tokens on the HTTP side map to NATS JWTs. This card defines
the JWT format so card 169 can reference it.

### 5. Smoke 24

`scripts/smoke/24-a2a-jwt-auth.sh`:
- Generate card with nsc-backed JWT auth fields.
- Publish to `a2a.discovery.<role>`.
- Retrieve via `get_peer_cards()` and assert `auth.scheme = nats-jwt`.
- Assert `issuer` matches configured operator NKey.
- Assert card with wrong issuer logs warning, still returned.

## Acceptance

- [ ] `aon-card gen` populates `auth.scheme = nats-jwt` when NSC present.
- [ ] Falls back to `nats-user` gracefully without NSC.
- [ ] Smoke 24 green.
- [ ] `scripts/gen-agent-cards.py` updated to match new auth block.

## Refs

- `aon-card/src/main.rs` — card generator (card 70 comment).
- `scripts/gen-agent-cards.py` — Python card generator.
- `agents/*.json` — current cards with placeholder auth.
- `team-alpha-a2a-http-sse-bridge.md` (169) — consumer of JWT scheme.
