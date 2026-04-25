---
column: Done
created: 2026-04-25
order: 40
---

# Onboard script — `onboard.sh <role>` for one-shot agent setup

Per-role onboarding. One command brings a fresh shell up to "ready to act".

## Scope

`scripts/onboard.sh <role>` where role ∈ {maya, raj, lin, sam, diego, priya}.

Steps:

1. **Validate env**: `TEAM_ALPHA_ROLE` matches arg, `TEAM_ALPHA_NATS_URL` set,
   creds file at `TEAM_ALPHA_CREDS` exists and readable.
2. **Discover bus**: `nats server check connection`. On fail, print VPN
   troubleshoot hint pointing to `docs/network.md` (from
   `team-alpha-vpn-network.md`) and exit non-zero.
3. **Post handshake**: publish `{type:handshake, role:<role>, host, ts}` to
   `agents.<role>.events`. Maya is subscribed to `agents.*.events` so this
   surfaces "X came online" without explicit roll-call.
4. **Refresh prompt**: `cat scripts/agent-prompts/<role>.md` (concat'd with
   `_common.md`).
5. **Print monitor commands** the agent should start as persistent Monitor tools
   in the session:
   - PRIMARY: `nats sub agents.<role>.inbox` (DMs).
   - PRIMARY: `nats sub board.tasks.<allowed-domains>.pending` (work queue).
   - PRIMARY: `nats sub broadcast.>` (everyone).
   - PRIMARY (Maya only): `nats sub agents.*.events` (situational awareness).
   - PRIMARY (growth subscribers): the `board.learning.>` scopes per role.
6. **Seed KV**: write `state.agent.<role>.load=active` and merge declared
   skills from `scripts/seed-skills.json` (created in `team-alpha-bootstrap.md`).

## Files

- `scripts/onboard.sh`

## Inputs

- Arg 1: role (required).
- Env: `TEAM_ALPHA_ROLE` (must match arg), `TEAM_ALPHA_NATS_URL`,
  `TEAM_ALPHA_CREDS`.

## Acceptance

- [ ] `bash scripts/onboard.sh maya` succeeds end-to-end given valid env +
      reachable NATS.
- [ ] Mismatched env vs arg fails fast with clear error.
- [ ] Handshake event visible to a subscriber on `agents.*.events` within 1s.
- [ ] Monitor commands printed are copy-pasteable (no shell-quoting hazards).
- [ ] Re-running is safe (idempotent KV merge; one handshake per session is
      acceptable).
- [ ] On NATS unreachable: prints VPN troubleshoot hint, exits non-zero.
