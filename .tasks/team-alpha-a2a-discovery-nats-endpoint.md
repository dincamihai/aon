---
column: Backlog
created: 2026-05-14
order: 167
---

# A2A NATS discovery endpoint

Currently agent cards are loaded from git files (`agents/<role>.json`).
Slice 2 requires a live NATS discovery surface so agents can query
peers at runtime without filesystem access — needed in VM sandboxes
and for cross-host teams.

## Deliverables

### 1. On-startup card publish

In `__main__.py`, after `client = TeamAlphaClient(...)`, publish the
agent's own card to `a2a.discovery.<ROLE>` on the `A2A_DISC` stream
(max-msgs-per-subject 1 — latest wins).

Use `aon-card publish` or inline the KV + subject write using the
existing `AgentCard` struct from `aon-card/src/main.rs`.

### 2. Request-reply endpoint

Spawn background subscription on `a2a.discovery.<ROLE>` requests
(reply-to pattern). Respond with own card JSON.
Allows `get_peer_cards()` to fall back to NATS request-reply when
KV cold or git unavailable.

### 3. `get_peer_cards()` upgrade

In `__main__.py:330-356`, extend the fallback chain:
1. NATS KV `agents.<role>.card` (current)
2. NATS request-reply `a2a.discovery.<role>` (new)
3. Git file `agents/<role>.json` (existing last-resort)

### 4. Card refresh on NATS reconnect

Re-publish card on reconnect event (JetStream reconnect hook) so
stale entries auto-heal after a network partition.

### 5. ETag cache for git fallback

When falling back to git-served cards, cache with mtime + ETag to
avoid redundant reads. Already partially done in `cards.py` (mtime);
add ETag header support for GitHub raw URLs.

## Acceptance

- [ ] `get_peer_cards()` returns live cards via NATS when git absent.
- [ ] Smoke 18 (`18-a2a-discovery.sh`) passes end-to-end.
- [ ] Card re-published on reconnect; verified by killing/restarting NATS.
- [ ] No regression in existing `scripts/smoke/run-all.sh`.

## Refs

- `team-alpha-a2a-smokes-18-19.md` — smoke 18 spec.
- `team-alpha-a2a-impl-slice2.md` — slice 2 umbrella.
- `mcp-server/src/aon_mcp/a2a/cards.py` — current card loader.
- `mcp-server/src/aon_mcp/__main__.py:330` — `get_peer_cards()`.
