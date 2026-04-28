---
column: Backlog
created: 2026-04-25
updated: 2026-04-28
order: 40
priority: high
blocks: waiting-room-admit
parent: onboarding-overhaul
children:
  - nsc-smoke-ci-hook
  - bootstrap-roster-stale-default
  - nats-server-conf-drift-prevention
---

# Migrate auth: user+password → NSC / JWT (decentralized accounts)

**Bumped to high (2026-04-28)** — `waiting-room-admit` needs JWT
creds for clean encrypt-to-pubkey and per-user revocation. No longer
deferred. Original deferral triggers below now satisfied via
waiting-room dependency.

Pick up when triggers (now applicable):
- Adding a second team / account boundary needed.
- Need credential rotation without server restart.
- Need revocation of a single user without redistributing `auth.conf`.
- Exposing NATS to the public internet (per-user signed creds > shared password file).

## Scope

Replace static `accounts {}` / `users {}` block in `nats-server.conf` with
operator-signed JWT auth via `nsc`.

Steps:

1. `nsc add operator aon-op` + push to a local resolver dir.
   (Operator + account names neutral per d54f794 rename. Per-team
   account derived from `aon.toml` `[team] account` field, e.g.
   `team-saas`.)
2. `nsc add account <team-account>` (e.g. `team-saas`).
3. For each user in the roster, `nsc add user <name>` with permissions translated
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

S1 — **NSC scaffolding (local)** ✅ DONE (2026-04-28)

`scripts/nsc-smoke/run-smoke.sh` proves the chain end-to-end against
a fixture team:

- `nsc` 2.12.2 installed via brew (note: `nk` formula removed from
  tap; nsc bundles nkey ops via `nsc generate nkey`).
- Operator `aon-op` + account `team-aon-smoke` + 4 users (sysadmin,
  manager, generalist, specialist) created in an isolated NSC home
  (`XDG_DATA_HOME` / `XDG_CONFIG_HOME` redirected to script tempdir).
- Permission claims translated 1:1 from `templates/auth/*.tmpl` via
  `nsc add user --allow-pub/--deny-pub/--allow-sub/--allow-pub-response`
  (comma-separated subject lists, `_INBOX.>` and `$JS.API.>` wildcards
  carried over verbatim).
- `.creds` files emitted per role.
- Throwaway `nats:latest` docker container booted with memory
  resolver (`resolver: MEMORY` + `resolver_preload` containing both
  SYS and team account JWTs — simpler than nats-resolver dir for
  smoke).
- 11 ACL parity cases pass: allow happy path per role, plus 7 forge
  attempts on disallowed subjects (deny-pub explicit + cross-role +
  cross-domain + KV-policy + sibling a2a). All rejects observed via
  permissions-violation error from nats CLI.

Gotchas captured:

- macOS Docker Desktop default file-shares don't include `/tmp` or
  `/var/folders` — work dir must live under `/Users` (script puts it
  in `scripts/nsc-smoke/.work/`).
- `include` paths in nats-server.conf are relative to the conf
  file's dir; absolute `/work/foo.conf` gets re-prefixed.
- nats CLI doesn't always exit non-zero on perm-deny; tests detect
  via stderr-match on "permissions violation" + GNU `timeout` (5s)
  to bound hang risk. Coreutils added as macOS dep (`gtimeout`).

Output of S1: a working translation pattern + a reproducible smoke
script. Engine code not yet touched — S3 wires it in.

S2 — **Server cutover** ✅ DONE (2026-04-28, commit 5b96be7)

- `nats-server.conf` (engine + template) flipped to `operator: @OP_JWT@`
  + `system_account: @SYS_ID@` + `resolver: { type: full, dir:
  /etc/nats/runtime/resolver }`. SYS account preloaded via
  `resolver_preload`.
- Placeholders rendered by `aon auth render`: @OP_JWT@, @SYS_ID@,
  @SYS_JWT@, @TEAM_NAME@.
- `scripts/bootstrap.sh` + `scripts/lib/nats-helpers.sh`: env vars
  flipped from `NATS_ADMIN_USER`+`NATS_ADMIN_PASSWORD` →
  `NATS_ADMIN_CREDS` (path to `.creds`). `nats_admin()` uses `--creds`.
- `templates/docker-compose.yml.tmpl`: dir bind-mount layout
  documented (resolver/<team-id>.jwt under `/etc/nats/runtime`).
- `nsc-smoke/run-smoke.sh` Phase C (135 lines): renders the real
  template, fail-fast on unsubstituted placeholders, boots
  nats:latest with prod-shape mounts, runs ACL parity, calls
  `bootstrap.sh` under `--creds` and asserts rc=0.
- Roster names in Phase A + C migrated to fixture-only
  (alice/bob/carol + dora/evan) — engine smoke decoupled from any
  consumer team roster.

Open subcards: `bootstrap-roster-stale-default`,
`nats-server-conf-drift-prevention`, `nsc-smoke-ci-hook`.

S3 — **`aon` integration** ✅ DONE (2026-04-28, commit 07c4098)

Wired engine to NSC/JWT so team init + role onboarding + joiner +
runtime nats CLI all use signed JWT creds. Driven end-to-end by aon.

- **lib `_aon-lib.sh`**: NSC helpers (env XDG redirect to
  `~/.aon/nsc/`, idempotent operator/account/user, kind→claims
  dispatch from `templates/auth/*.tmpl`, getters for
  op_jwt/sys_id/sys_jwt/team_id/team_jwt, publish_team_jwt to
  resolver dir). Renamed `_aon_role_pwfile` → `_aon_role_creds`
  (`.password` → `.creds`); old name kept as alias for soak.
- **`cmd_auth_render`**: 4-step NSC pipeline (operator+account+users
  → resolver dir → render `nats-server.conf` with placeholders
  substituted; refuses unsubstituted output).
- **`cmd_auth_set_passwords`**: deprecation stub (warns +
  suggests `aon creds`).
- **`cmd_creds` / `cmd_creds_all`**: emit `.creds` via
  `nsc generate creds` (--all enumerates NSC users).
- **`cmd_bootstrap`**: env switched to
  `NATS_ADMIN_CREDS=<sysadmin.creds>` (auto-emits if missing).
- **`cmd_launch / cmd_monitor / cmd_pub / cmd_sub / cmd_req /
  cmd_resolve_env`**: `--creds <path>` instead of `--user`/
  `--password`; exports `AON_CREDS`.
- **`cmd_join`**: `<role>.creds` lookup; calls `cmd_creds` if
  missing on operator side, else fails with clear msg.
- **`cmd_onboard`**: handshake probe via `--creds`; emits **token
  v3** carrying `creds:` blob (full `.creds` content) instead of
  password.
- **`cmd_join_link`**: parses v3 tokens; rejects v2 (password) with
  directive "ask operator to regenerate v3".
- **`cmd_set_nats_url`**: probe via `--creds`.
- **`cmd_doctor`**: checks rendered `nats-server.conf` (no leftover
  placeholders), resolver dir has `*.jwt`, NSC + gtimeout deps;
  legacy `auth.conf` / `.passwords` downgraded to warns.

S4 scope-bleed captured (deferred to S4):
- `scripts/coordinator-watcher.sh`, `scripts/migrate-2026-04-skills-kv.sh`,
  `scripts/smoke/_lib.sh`, `scripts/smoke/_sim_lib.sh`,
  `scripts/smoke/{12,13,15,16,17b,21,22,24,25}*.sh` still reference
  `NATS_ADMIN_PASSWORD` / `--user/--password` / `SMOKE_PASS` /
  `TeamAlphaClient(role,url,pw)`. Cutover during S4 per-host
  `.creds` distribution.

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

### Why now urgent (2026-04-28 pivot)

`waiting-room-admit` requires JWT for clean creds delivery:

- **Encrypt-to-pubkey**: signed JWT is a self-contained string;
  cleaner to seal in a libsodium box than rolling our own
  password-envelope format.
- **Per-user revoke**: kicking a compromised joiner without
  affecting others requires `nsc revocations add-user` (no
  server restart). Password-file rewrite + reload affects all
  users on every admit.
- **Rotation cadence**: waiting-room flow can re-issue creds
  on demand. JWT supports expiry + refresh natively.
- **Audit**: signed creds carry issuer + tag, easier to trace
  back to admit event.

Rolling forward without JWT is possible (encrypt password,
restart on each admit) but builds waiting-room on a fragile
foundation. Land NSC first, then waiting-room on top.

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
