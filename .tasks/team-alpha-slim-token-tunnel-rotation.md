---
column: Backlog
created: 2026-04-27
order: 1060
priority: high
---

# Slim token + cloudflared bits arg + tunnel rotation + self-contained join

## Problem

Today's Vahid/john trial exposed three UX gaps in the
`aon onboard` / `aon join-link` flow:

1. **`nats_url` lives inside the token.** Trycloudflare URLs rotate
   every cloudflared restart. Embedding the URL means every rotation
   = full re-onboard. We also hit the placeholder leak today: the
   token carried `wss://nats.example.com` because `aon.toml` was never
   edited.
2. **`nats_url` would also leak if stored in `aon.toml`.** That file
   is committed in the team-aon repo. Anyone with read access learns
   the live tunnel address. Capability creep.
3. **Joiner install is too heavy.** `git clone + pipx install --editable`
   is engine-developer workflow. Joiners just run `aon join-link`
   once; they don't modify the engine. They shouldn't need an editable
   live checkout.

## Proposal

### A. Slim token (v2)

Drop `nats_url` from the `aon://...` blob. Token holds only durable,
non-secret-leaky values:

```json
{
  "v": 2,
  "team_repo_url": "https://github.com/<owner>/<team>-aon",
  "role": "john",
  "password": "<48-hex>",
  "expires_at": "2026-04-27T19:00:00Z",
  "engine_sha": "abc1234"
}
```

`v1` tokens (with `nats_url`) still accepted by `aon join-link` during
a transition window, with a deprecation warning.

### B. Cloudflared bits travel separately, OOB-only

Bits = the random 4-word subdomain piece of a trycloudflare URL
(e.g. `transportation-repeated-ppm-bobby` for
`wss://transportation-repeated-ppm-bobby.trycloudflare.com`). They
are **never** committed:

- `aon.toml [nats] ws_url` is empty or a literal placeholder. Never
  the live URL.
- Bits travel exclusively via OOB channels (1Password / private DM).
- Token + bits combine to grant access. Either alone is insufficient
  to connect.

### C. `aon onboard <name> <bits>`

Bits become a **required** positional arg:

```bash
aon onboard john transportation-repeated-ppm-bobby
```

Output ends with a single curl line for the operator to DM:

```
════════════════════════════════════════════════════════════════════
  ✓ ONBOARDING COMPLETE for: john
════════════════════════════════════════════════════════════════════

Send this ONE command to the joiner (1Password / private DM only):

  curl -sL https://raw.githubusercontent.com/dincamihai/ai-over-nats/main/scripts/join-link.sh \
    | bash -s -- aon://eyJ... transportation-repeated-ppm-bobby

Token expires: 2026-04-27T19:00:00Z
If tunnel rotates: aon set-nats-url <new-bits>
Watch traffic:    aon monitor john
════════════════════════════════════════════════════════════════════
```

### D. `aon join-link <token> <bits>`

Joiner command takes both args. Builds the NATS URL itself:

- Default: `wss://<bits>.trycloudflare.com`
- Named tunnel / arbitrary URL: `--url wss://nats.your-domain` flag.

**Cold join**: clones team-aon repo, places creds, stamps work-repo,
probes handshake.

**Re-run with new bits** (rotation mode): detects existing creds +
stamped work-repo, only updates URL in `~/.team-alpha/<role>.env`,
`<work-repo>/.mcp.json`, `<work-repo>/.claude/settings.json`. ~5s,
no clone, no password prompt.

### E. `aon set-nats-url <bits>` (joiner standalone)

Pure rotation command. No token required. Discovers role from
`$TEAM_ALPHA_ROLE` or from existing `~/.team-alpha/<role>.env`.
Updates the same three files as join-link rotation mode. Re-probes
handshake. Tells joiner to restart `claude` if running.

### F. `scripts/join-link.sh` — self-contained, zero install

Single bash script in the engine repo. Joiners do NOT need
`pipx install --editable`. They run:

```bash
curl -sL https://raw.githubusercontent.com/dincamihai/ai-over-nats/main/scripts/join-link.sh \
  | bash -s -- <token> <bits>
```

Script is self-contained — no source of `_aon-lib.sh`, no engine
clone. Inline implements:
- token base64 decode + jq parse + expiry check
- `git clone <team_repo_url>` to `~/Repos/<team>-aon`
- password file write
- NATS URL construction from bits
- handshake probe
- `<work-repo>` prompt + standard stamping (calls remote `aon join`
  via the freshly cloned engine? OR rewrite the stamping inline).

**Cross-platform** (Linux + macOS):
- shebang `#!/usr/bin/env bash`
- macOS `date -v+1H` vs Linux `date -d '+1 hour'` → use python3
  one-liner for expiry check
- macOS `sed -i ''` vs Linux `sed -i` → write to temp + mv pattern
- `base64 -d` flag works on both
- deps stated upfront: `bash`, `jq`, `nats`, `git`, `curl`, `python3`

### G. Operator-side rotation: drop `aon rotate-tunnel-url`

Originally proposed to patch `aon.toml` + commit + push. Removed because
**bits never go in aon.toml**. Instead:

- After cloudflared restart: operator notes the new bits from the
  log, DMs them to all active joiners.
- Joiners run `aon set-nats-url <new-bits>`.
- For onboarding new joiners post-rotation: operator passes the
  current bits to `aon onboard <name> <bits>`.

Optional convenience: a local-only `~/.team-alpha/<team>.bits` cache
file (chmod 600, gitignored, never the team repo) so the operator
can `aon onboard <name>` without re-typing the bits each time. Bits
flow into the cache via `aon set-tunnel-bits <bits>`.

### H. Validate aon.toml before emitting token

`aon onboard` aborts if `[nats] ws_url` is non-empty AND non-placeholder
(reverse of the previous proposal — the *only* acceptable values are
empty or the documented placeholder `wss://YOUR-CURRENT-TUNNEL.trycloudflare.com`).
Forces operators to keep live URLs out of the committed file.

### I. Update skills

- `skills/aon/join.md` — rewrite as the curl one-liner. Drop
  pipx/editable install steps.
- `skills/aon/rotate-tunnel.md` — primary path becomes "DM new bits
  to joiners; tell them to run `aon set-nats-url <bits>`". Drop the
  `aon.toml` patching path.
- New `skills/aon/set-nats-url.md` — joiner-side rotation skill.
- `skills/aon/add-role.md` / `trial-test.md` — update to include the
  bits arg on `aon onboard`.

## Files to modify / create

| File | Change |
|---|---|
| `bin/aon` | `cmd_onboard`: required bits arg, v2 token JSON, validate aon.toml ws_url is unset/placeholder, emit curl line. `cmd_join_link`: required bits arg + rotation mode + URL building. New `cmd_set_nats_url`. New optional `cmd_set_tunnel_bits` for operator's local cache. Dispatch table updates. |
| `scripts/join-link.sh` | NEW — self-contained cross-platform joiner script |
| `skills/aon/join.md` | curl one-liner; drop pipx |
| `skills/aon/rotate-tunnel.md` | OOB-only flow; drop aon.toml patching |
| `skills/aon/set-nats-url.md` | NEW |
| `skills/aon/add-role.md`, `trial-test.md` | bits arg on onboard |
| `README.md` | §1.5 onboard call adds bits; §2 single curl |

## Acceptance

- [ ] `aon onboard <name> <bits>` accepted; bare `aon onboard <name>`
      rejected with usage hint.
- [ ] `aon onboard` aborts if `aon.toml [nats] ws_url` is set to a
      live URL (not placeholder, not empty).
- [ ] Token v2 has no `nats_url` field.
- [ ] `aon join-link <token> <bits>` runs end-to-end on cold box;
      builds `wss://<bits>.trycloudflare.com`; handshake green.
- [ ] Re-running `aon join-link <token> <new-bits>` enters rotation
      mode (no clone, no password prompt) in < 10s.
- [ ] `aon set-nats-url <bits>` updates env + mcp.json + settings.json,
      probes handshake, prints "restart claude" hint.
- [ ] `scripts/join-link.sh` runs identically on Linux + macOS via
      `curl | bash -s -- <token> <bits>` with no engine clone.
- [ ] README §2 collapses to a single curl line.
- [ ] Skills updated.

## Non-goals

- magic-wormhole / 3rd-party rendezvous (user rejected).
- Encrypting the token beyond base64 (password is the secret; same
  threat model as today's OOB password share).
- Federated multi-team operator workflows.

## Triggered by

2026-04-27 Vahid/john trial test:
- token leaked `wss://nats.example.com` placeholder.
- joiner had to git-clone engine + pipx-install before joining.
- no clean path to rotate the tunnel URL post-onboard.

## References

- Parent: `.tasks/team-alpha-streamline-onboarding-handshake.md`
  (PR #29 — token v1 + initial onboard/join-link).
- PR #30 — colima force-recreate / role-permitted probe / engine cwd
  guard — foundation this card builds on.
- `skills/aon/*.md` — skill set to update in §I.
