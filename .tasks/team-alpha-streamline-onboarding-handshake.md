---
column: Backlog
created: 2026-04-27
order: 1050
priority: high
---

# Streamline onboarding: 15 min → 3 min, two commands total

## Problem

Today's Vahid trial onboarding took ~15 min wall time even with a
prepared operator. Breakdown:

**Operator side (~7 min)**: 9 discrete commands, each a chance to
skip a step. Skipping `aon nats up` after `aon auth set-passwords`
gave us today's "5h-old container running stale auth" bug → 1
joiner blocked, 1 round-trip diagnostic, 1 PR (#26).

**Joiner side (~5 min)**: 5 manual steps, two of which are friction
sources we hit live:
- Wrong cwd at `aon join` time → "role 'X' not in roster" (PR #25).
- Typing `https://` instead of `wss://` at the URL prompt → handshake
  EOF.
- Manual chmod 600 on the password file with hex glyph copy hazard
  (the `→` literal-arg incident).

**Cross-machine (~3 min)**: out-of-band password + URL transfer is
manual paste + risk of password landing in chat.

The 8 skills shipped in PR #28 compress the *recall* problem but
don't compress the *number of commands*. Skills tell you what to
type; they still need typing.

## Proposal

Two new `aon` subcommands collapse the entire flow to **two human
commands** (one operator, one joiner). Time-to-handshake target:
**3 min** (mostly `git clone` + `pipx install` on a cold joiner box).

### Operator side: `aon onboard <name>`

Idempotent composition. Each step skipped if already done.

```
aon onboard vahid                        # default kind=generalist, domain=fullstack
aon onboard vahid generalist backend     # explicit
```

Composes:

1. `aon add-role <name> <kind> <domain>` (skip if already in roster).
2. `aon prompts render` (always — cheap; idempotent).
3. `aon auth render && aon auth set-passwords` (idempotent).
4. `aon creds <name>` (skip if `~/.team-alpha/<name>.password` present).
5. `aon nats up` (always — restart if container running, up if down).
6. **Local handshake probe** as `<name>` against `nats://localhost:4222`.
   Hard fail if red — surfaces stale-auth, missing-user,
   password-mismatch *before* joiner is involved.
7. `git add -A && git commit -m "Onboard <name> ..." && git push`
   (skip if no changes; warn if dirty).
8. **Emit a share-block token** — see `Token format` below.
9. `aon doctor` end-of-flow sanity check.

Failure modes are sharp: any step's failure stops the chain with a
clear remediation hint. No partial state, no "did I forget something".

### Joiner side: `aon join-link <token>`

Single paste. Decodes the token, runs the rest.

```
aon join-link aon://eyJ0ZWFt...
```

Steps:

1. **Engine install** (skip if `aon` already on PATH and matches the
   token's engine sha — TODO follow-up; for v1 just check `aon -h`).
2. **Decode token** → `{team_repo_url, role, nats_url, password,
   work_repo_default}`.
3. **Clone team-aon repo** to `~/Repos/<team>-aon` (skip if dir
   present and `aon.toml` matches).
4. **Place password** at `~/.team-alpha/<role>.password` (chmod 600,
   no trailing newline).
5. **Prompt for `<work-repo>` path** (default = token's
   `work_repo_default`, can override). Verify exists.
6. **Run `aon join <role> <work-repo>`** (existing flow — handshake,
   stamping, hooks, brief symlink).
7. **Print** `cd <work-repo> && claude` line.

Joiner cannot mistype the NATS URL or scheme — it's in the token.
Joiner cannot put the password in the wrong place — `aon` writes it.
Joiner cannot run `aon join` from the wrong cwd — `aon join-link`
is `cd`-aware.

### Token format

Base64-url-encoded JSON:

```json
{
  "v": 1,
  "team": "team-poc",
  "team_repo_url": "https://github.com/dincamihai/team-poc-aon",
  "role": "vahid",
  "nats_url": "wss://punk-registration-collector-opinion.trycloudflare.com",
  "password": "<48-hex>",
  "work_repo_default": "~/Repos/team-poc-work",
  "engine_sha": "<short-sha>",
  "expires_at": "2026-04-27T18:00:00Z"
}
```

- `v` — schema version. Bumped on incompatible changes.
- `engine_sha` — operator's engine HEAD. Joiner pins to it for
  prompt/MCP parity.
- `expires_at` — TTL ~60 min. After expiry, `aon join-link` refuses
  with "token expired; ask operator to regenerate".

**Security**: token contains the password in plaintext (base64
isn't encryption). Same threat model as the current OOB password
share. **Operator delivers via 1Password share link / private DM,
never plain chat.** Document this loud in the help output.

Future hardening (separate slice, not in this card):
- 1Password CLI integration: `aon onboard --share-via op` writes
  the token to a one-time op-share URL; operator copies the URL,
  sends URL not token.
- Short-lived tokens via signed envelope (depends on
  ed25519 / JWT migration — see
  `team-alpha-crypto-identity-integrity.md`).

### Side effects on existing surface

- `aon join <role> <work-repo>` keeps working as-is. `aon
  join-link` is a thin wrapper that resolves inputs and calls it.
- `aon onboard` reuses every existing subcommand. No duplication.
- `aon add-role` defaults: if `kind` omitted → `generalist`.
  If `domain` omitted → `fullstack`. Most trial joiners fit both.
  Specialist case stays as `aon onboard <name> specialist <skill>`.
- `aon creds` keeps the bare-arg invocation; the `→` glyph footgun
  is also addressed: refuse positional args that look like
  documentation glyphs (`→`, `←`, `⇒`) with "looks like a comment
  glyph; did you copy-paste with `#`?".

## Acceptance

- [ ] `aon onboard <name>` ships and runs end-to-end < 30s on a
      warm operator box (NATS + tunnel already up).
- [ ] `aon onboard` is idempotent: re-running with no roster
      changes prints "all green" and exits 0.
- [ ] Local handshake probe runs as `<name>` against
      `nats://localhost:4222` after step 5; failure aborts the chain
      with a clear hint pointing at `/aon:diagnose-handshake`.
- [ ] `aon onboard` outputs a single share-block token, plus one
      DM-paste-ready summary line, on stdout.
- [ ] `aon join-link <token>` ships and runs end-to-end < 3 min on
      a cold joiner box (most time = git clone + pipx install).
- [ ] `aon join-link` refuses expired tokens with a clear message.
- [ ] `aon join-link` cannot land password in shell history (uses
      stdin / temp file, not argv).
- [ ] `aon add-role` defaults `kind=generalist`, `domain=fullstack`
      when omitted; warns if domain is not in
      `acl.PRIMARY_SKILLS`.
- [ ] `aon creds` rejects positional `dest` args that match
      documentation glyphs (`→`, `←`, `⇒`) with the helpful hint.
- [ ] README §1.5 collapses to `aon onboard <name>`. README §2
      collapses to `aon join-link <token>`. Old per-step
      sequences remain in §1.5.x / §2.x for advanced operators
      who need the granular form.
- [ ] `/aon:add-role` skill rewrites to call `aon onboard` first;
      `/aon:trial-test` ditto. `/aon:join` rewrites to call
      `aon join-link`.

## Non-goals

- 1Password CLI integration for token delivery. Captured but
  deferred to a follow-up card.
- Eliminating the password entirely (would require ed25519 / JWT
  migration; see `team-alpha-crypto-identity-integrity.md`).
- Auto-cloning the joiner's `<work-repo>`. They still bring their
  own code repo — too much variance to automate.

## Triggered by

2026-04-27 Vahid trial onboarding live-test. Pain points list:

| Pain | Source | Eliminated by |
|---|---|---|
| Operator forgets `aon nats up` | 9-step manual flow | step 5 of `aon onboard` |
| Joiner cwd wrong → "role not in roster" | manual `cd` | `aon join-link` cd's correctly |
| Joiner types `https://` not `wss://` | manual prompt | URL is in token |
| `→` glyph copy-paste creates stray file | doc-comment hazard | `aon creds` arg validation + flow eliminates need to retype |
| Password landing in chat | manual OOB paste | 1Password share-link recommended in help |
| Operator-path leaks in joiner settings | (already fixed PR #26) | — |

## References

- README §1–§2.5 — flow this card collapses.
- PR #25 — README clarifications this card supersedes for the typical
  joiner; granular form retained for advanced operators.
- PR #26 — hooks install fix (already landed, complementary).
- PR #27, PR #28 — skills card + implementation; this card adds the
  primitives the skills compose.
- `team-alpha-crypto-identity-integrity.md` — long-term identity layer
  that eventually replaces shared-password tokens.
- `team-alpha-roster-multi-skill-schema.md` — orthogonal: lets a
  generalist declare multiple skills, complements `aon onboard`'s
  default of `generalist/fullstack`.
