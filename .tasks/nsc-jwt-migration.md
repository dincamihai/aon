---
column: Backlog
created: 2026-04-25
order: 1000
priority: deferred
---

# Migrate auth: user+password → NSC / JWT (decentralized accounts)

**Deferred** — pick up only when one of these triggers:
- Adding a second team / account boundary needed.
- Need credential rotation without server restart.
- Need revocation of a single user without redistributing `auth.conf`.
- Exposing NATS to the public internet (per-user signed creds > shared password file).

## Scope

Replace static `accounts {}` / `users {}` block in `nats-server.conf` with
operator-signed JWT auth via `nsc`.

Steps:

1. `nsc add operator team-alpha-op` + push to a local resolver dir.
2. `nsc add account team-alpha`.
3. For each of the six users, `nsc add user <name>` with permissions translated
   from current `nats-server.conf` (allow/deny lists become JWT claims).
4. Output `.creds` file per user → distribute via secret manager.
5. `nats-server.conf`: replace `authorization {}` block with `operator: <jwt>`
   and `resolver: { type: full, dir: ./resolver }`.
6. Update `bootstrap.sh` to use admin `.creds` instead of `--user/--password`.
7. Update `docker-compose.yml` to mount resolver dir.
8. Doc rotation runbook: `nsc edit user <name> ...` + `nsc push`.

## Acceptance

- [ ] `team-alpha-nats-config.md` deliverables ported to NSC equivalents.
- [ ] All six users connect with `.creds` file, permissions verified by attempted
      publish/subscribe on disallowed subjects (must reject).
- [ ] Revoking one user (`nsc revocations add-user`) takes effect without
      restarting nats-server.
- [ ] Old user+password block fully removed from `nats-server.conf`.
- [ ] Cluster routes still work post-migration (multi-host).

## Findings — 2026-04-27 scoping pass

Concrete sizing before next attempt. Captured during the
`crypto-identity-integrity` parent grouping discussion.

### Tooling not yet installed

- `nsc`, `nk` — install via `brew install nats-io/nats-tools/nsc
  nats-io/nats-tools/nk`. `nats` is already on PATH.
- One-time operator dir: pick a stable location for the resolver
  (proposed `./nats/resolver/`, gitignored except for the operator
  pubkey / account JWT references). Operator + account seeds NEVER
  committed.

### Real surface area (measured)

- `nats/auth.conf` is **288 lines**, 7 roles (sysadmin + mihai + raj
  + lin + sam + diego + priya — note: card text said "six users", but
  `auth.conf` already has seven; vahid joining makes eight). Each role
  has its own allow/deny block on publish AND subscribe. All of that
  needs translation into JWT permission claims via `nsc edit user
  <name> --allow-pub ... --deny-pub ... --allow-sub ... --deny-sub
  ...` — no shortcut, every subject pattern carried over verbatim.
- `MODEL.md` is 360 lines and is the source-of-truth for the
  permission contract. JWT claims must preserve it.
- Wildcards (`agents.*.inbox`, `board.tasks.*.>`, `$KV.team-state.>`)
  translate cleanly; `_INBOX.>` and `$JS.API.>` need explicit
  allow-pub for request/reply + JetStream API.
- `allow_responses: true` (currently used by every role) maps to
  `--allow-pub-response` in nsc; verify the permission shape is
  preserved for inbox-reply patterns.

### Slice plan (when triggered)

S1 — **NSC scaffolding (local)**: install tools; init operator
`team-alpha-op`; init account `team-alpha`; add all roles as users;
translate every `auth.conf` permission block into nsc commands;
generate `.creds` files; commit operator JWT + account JWT + resolver
dir scaffolding (creds gitignored). Smoke test: roles connect to a
local nats-server in JWT mode, perm-deny checks pass.

S2 — **Server cutover**: `nats-server.conf` flipped to `operator:
<jwt>` + `resolver: { type: full, dir: ./nats/resolver }`. Old
`authorization{}` block removed. `docker-compose.yml` mounts resolver
dir. `bootstrap.sh` uses admin `.creds` instead of `--user/--password`.

S3 — **`aon` integration**: rewrite `aon creds` to write `.creds`
files (replacing per-role passwords). `aon launch / monitor / join`
export `NATS_CREDS=<path>` instead of password env. Update README
section 4 (creds workflow) accordingly.

S4 — **Live cutover + smoke**: per-host distribution of `.creds`;
rolling reconnect of all 7+ roles; verify ACL parity vs old
`auth.conf` (forge attempt: each role tries publish on disallowed
subject, must reject); test `nsc revocations add-user` + `nsc push`,
confirm takes effect without `nats-server` restart.

S5 — **Rotation runbook + Sub B hand-off**: doc `nsc edit user
<name> --tag rotated` + republish; doc the one-liner to extract a
role's Ed25519 nkey seed from its `.creds` (Sub B input). Sub B can
start once S5 is published.

### Live-cluster cutover risks

- Existing roles connect via user/password. The cutover is a hard
  switchover (server can't run both `authorization{}` and `operator:`
  at once). Plan: bring substrate down briefly, swap config, bring
  back up; all roles reconnect via `.creds`. Window <60s achievable.
- `auth.conf` is gitignored and currently holds real passwords. Once
  cutover lands, the file becomes obsolete — keep around only for
  rollback during soak window, then delete.
- AUDIT mirror keeps signing keys via the operator; no JetStream
  schema change required, but verify subject-mapping permissions on
  the AUDIT consumer survive translation.

### Why still deferred

None of the parent triggers fire today (single team, no public NATS
exposure, no rotation pressure, no forge threat in scope yet). HMAC
envelope (PR #21, parked Draft) covers tamper + replay protection
in the meantime. Wake this card when:

- A second team / account boundary is needed.
- Credential rotation without server restart becomes urgent.
- Per-user revocation without redistributing `auth.conf` is needed.
- NATS is exposed to the public internet.
- Forge-resistant per-message identity becomes urgent (then prioritise
  Sub A so Sub B can land).

### Estimate

S1+S2+S3 ≈ 1 day if focused. S4 (live cutover + smoke across all
hosts) ≈ ½ day, **must** run with operator paying attention. S5 ≈ ½
day. Total ~2 focused days end-to-end, not counting soak window
between S2 and S3 if cutover is staged.

## References

- [MODEL.md](../MODEL.md) — permission contracts that JWT claims must preserve.
- [team-alpha-nats-config.md](team-alpha-nats-config.md) — source-of-truth permission
  mapping to translate.
- NATS docs: https://docs.nats.io/running-a-nats-service/configuration/securing_nats/auth_intro/jwt
