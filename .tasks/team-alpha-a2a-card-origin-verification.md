---
column: Backlog
created: 2026-05-14
order: 172
---

# A2A card origin verification (NATS-ACL-backed)

## Context

Agent cards are stored in KV under `agents.<role>.card`. NATS ACL
already enforces that only `<role>` can write `$KV.<bucket>.agent.<role>.>`
(verified in `scripts/nsc-smoke/run-smoke.sh` line ~103-119). No other
role can forge a peer's card — trust is implicit via NATS JWT auth.

Currently `get_peer_cards()` reads card bytes from KV and returns them
with no verification step. The trust guarantee exists but is invisible
and undocumented. A card tampered with outside NATS (e.g. direct KV
injection via compromised creds) would be silently accepted.

No JWT NKey fingerprints in card JSON are needed — that's card 171
(external-only, blocked on card 169). Internal trust = ACL.

## Deliverables

### 1. Document trust model

Add section to `MODEL.md` §A2A layer:

> Card authenticity: each role's card KV key (`agents.<role>.card`)
> is writable only by that role's NATS creds (`$KV.<bucket>.agent.<role>.>`).
> Authenticity is enforced at the NATS ACL layer — no separate signing
> needed for intra-team use.

### 2. KV metadata check in `get_peer_cards()`

NATS JetStream KV entries carry `Entry.revision` and the publishing
subject in stream metadata. Add optional check:

```python
entry = await kv.get(f"agents.{role}.card")
# KV subject for this key: $KV.<bucket>.agents.<role>.card
# ACL guarantees only <role> can write here — log warning if
# entry subject doesn't match expected pattern.
expected_subject = f"$KV.{KV_BUCKET}.agents.{role}.card"
if hasattr(entry, 'subject') and entry.subject != expected_subject:
    logger.warning("card_origin_mismatch role=%s subject=%s", role, entry.subject)
```

Warn only — don't drop the card. Visible signal without hard failure.

### 3. `verify_card_acl_scope()` helper

In `mcp-server/src/aon_mcp/a2a/cards.py`, add:

```python
def verify_card_acl_scope(role: str, entry_subject: str, kv_bucket: str) -> bool:
    """Return True if entry subject matches expected ACL-scoped KV key."""
    expected = f"$KV.{kv_bucket}.agents.{role}.card"
    return entry_subject == expected
```

Called by `get_peer_cards()` for the warning above.

### 4. Smoke addition to smoke 18

Extend `scripts/smoke/18-a2a-discovery.sh`:
- Assert role cannot overwrite another role's card KV key (pub denied).
- Assert own card KV key writeable.

Already partially covered by smoke 19 ACL matrix — add explicit card
write test to smoke 18 as it's the discovery smoke.

## Acceptance

- [ ] `MODEL.md` trust model documented.
- [ ] `get_peer_cards()` logs warning on subject mismatch.
- [ ] `verify_card_acl_scope()` helper in `cards.py`.
- [ ] Smoke 18 asserts cross-role card write denied.

## Refs

- `mcp-server/src/aon_mcp/__main__.py:333` — `get_peer_cards()`.
- `mcp-server/src/aon_mcp/a2a/cards.py` — card loader.
- `scripts/nsc-smoke/run-smoke.sh:103-119` — ACL definition.
- `team-alpha-a2a-jwt-auth-migration.md` (171) — external identity,
  postponed until card 169.
