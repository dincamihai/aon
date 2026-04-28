---
column: Backlog
created: 2026-04-28
order: 30
priority: high
type: epic
children:
  - nsc-jwt-migration
  - waiting-room-admit
  - streamline-aon-join
  - operator-spawn-helpers
---

# Onboarding overhaul — JWT creds + waiting-room admit + streamlined join

Umbrella epic for re-shaping how operators bring new agents (humans
+ Claude sessions) onto a team. Replaces the current
`aon onboard NAME BITS` + `aon join-link TOKEN BITS` token-paste flow
with a JWT-backed waiting-room admit pattern.

## Why now

Pain points compounding:

- Per-joiner `aon onboard` work for admin doesn't scale.
- Token+bits shared out-of-band leaks (Slack, email).
- Role pre-bound to token → mistake = redo.
- URL prompt clobber bug (✅ fixed) was symptom of a fragile
  imperative join script.
- Per-repo MCP install (✅ fixed) cleared scope but the rest of join
  is still bespoke per-team.

## End state

```bash
# admin one-time
aon up                       # init + add-roles + nats up + share URL

# admin shares: "team url: wss://xyz.example.com"

# joiner box (one cmd)
aon connect wss://xyz.example.com
# admin live-approves via `aon admit`
# creds (JWT) delivered encrypted to ephemeral keypair
# joiner box: NATS handshake ✓ + welcome card

claude                       # agent self-bootstraps MCP / prompts
```

Two commands. No tokens shared. Crypto-protected creds delivery.
Live identity check.

## Children

| Order | Card                       | Role                             |
|-------|----------------------------|----------------------------------|
| 40    | `nsc-jwt-migration`        | Creds = signed JWT (foundation). |
| 50    | `waiting-room-admit`       | Replace token paste with admit.  |
| 95    | `streamline-aon-join`      | Joiner-side post-admit polish.   |

## Dependency chain

```
nsc-jwt-migration  →  waiting-room-admit  →  streamline #12
                                          \→  streamline #4–#11 (parallel)
```

streamline #1, #2, #9 already shipped; rest can land in parallel
with waiting-room work since they're joiner-side post-bootstrap.

## Acceptance (epic-level)

- New joiner onboarded by admin in ≤ 2 minutes from "share URL" to
  "agent claims first task".
- Zero per-joiner pre-work for admin (no `aon onboard X` script
  runs).
- Zero secrets in clear on the wire (creds encrypted to joiner
  pubkey).
- Admit + revoke logged + auditable.
- Re-running any flow command on an already-set-up box is a no-op.

## Out of scope (epic)

- Multi-admin quorum approval.
- Auto-admit / pre-shared invite codes.
- Multi-team-per-host scenarios.
- Federation across operator orgs.
