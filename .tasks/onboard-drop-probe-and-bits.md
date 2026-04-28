---
column: In Progress
created: 2026-04-28
order: 75
priority: normal
parent: onboarding-overhaul
---

# `aon onboard`: drop bits arg + handshake probe (delegate to doctor)

`aon onboard NAME BITS [KIND] [DOMAIN]` requires the operator to
re-pass cloudflared bits as a positional arg and runs an inline
handshake probe to verify the new role can connect.

Both are redundant:

1. **Admin already has bits on their own box** (saved in env via
   prior `aon set-nats-url BITS`). Re-passing is duplicate input
   that can drift (operator types wrong bits → onboard works but
   for a stale URL → token emitted with bad URL).
2. **`aon doctor` already verifies env health** (NATS reachable,
   creds valid, auth resolves). If doctor is green, an inline
   onboard probe re-proves the same thing.

## Goal

Single responsibility per command:

| Command          | Job                                     |
|------------------|-----------------------------------------|
| `aon doctor`     | "is my env healthy?" (one check, one place) |
| `aon onboard`    | "mint role + emit token" (pure issuance)    |
| `aon join-link`  | "joiner: connect using token" (joiner's own probe) |

## Changes

### `cmd_onboard`

- Drop the `BITS` positional arg.
- Read NATS URL from env / saved config (`AON_NATS_URL` from
  `~/.aon/teams/<team>/admin.env` or equivalent).
- Drop the inline handshake probe block.
- If env vars are unset, fail with directive: "no AON_NATS_URL —
  run `aon set-nats-url BITS` first."
- New signature: `aon onboard NAME [KIND] [DOMAIN]`.

### `cmd_join_link`

- Already probes joiner's connection. Keeps probe.
- Token continues to carry the URL (joiner's bits arg redundant?
  consider follow-up — token v3 already encodes URL).

### Optional: opt-in probe flag

- `aon onboard --probe NAME` keeps the inline probe for paranoid
  operators. Not the default.

## Acceptance

- `aon onboard mihai manager fullstack` (no BITS) succeeds when
  env is set + healthy.
- Token emitted carries the correct URL from env.
- `aon onboard` fails with clear directive if env is unset.
- `aon doctor` is the documented entry point for "is my env
  healthy?" — README + help text updated.
- Re-running `aon onboard` repeatedly with stale env shows the
  same URL drift symptom only via `aon doctor` (one place to look).

## Out of scope

- Removing bits from `aon join-link` (joiner side genuinely needs
  it; covered separately by `waiting-room-admit` which kills the
  whole bits flow).
- Token v3 → v4 (no token format change needed for this card).

## Order to do

1. Read existing `cmd_onboard` flow; identify the probe block
   and BITS handling.
2. Replace BITS arg with env-read + fail-fast directive.
3. Drop the probe block; emit "run `aon doctor` if joiner reports
   issues" hint in success output.
4. `--probe` opt-in flag if anyone asks (otherwise skip).
5. Update README + `aon help` text.
6. Smoke: onboard with healthy env succeeds; with broken env fails
   with clear pointer to doctor.
