# NSC/JWT cutover playbook

One-shot playbook for taking a team substrate from the legacy
user/password auth model (`auth.conf` + `.passwords`) to the
NSC/JWT auth model (operator-signed user JWTs + dir-based account
resolver).

Target window: substrate-down to substrate-up under **60 seconds**.

Audience: operator running this on the team's primary NATS host.
Coordinated with all role joiners ahead of time so they re-pull
creds in the same window.

Scope: per-team, one-shot. Re-runs are safe but no-ops once the
account JWT is in place.

---

## 0. Pre-flight (operator host)

Verify tooling:

```bash
nsc --version            # 2.12+ required (we tested against 2.12.2)
which gtimeout || which timeout    # GNU timeout — used by smoke
docker ps                # nats container should be running on legacy auth
```

Verify aon doctor agrees you're in the team repo:

```bash
cd ~/Repos/team-<name>
aon doctor               # should NOT bad-flag legacy auth.conf yet
```

Confirm every joiner is reachable on Slack/equivalent — they will
need to re-pull creds within the cutover window.

---

## 1. Mint the NSC artifacts (operator only — ~5s)

This step is **non-destructive**: it creates an isolated NSC home
under `~/.aon/nsc/`, mints operator + account + per-role users, and
emits per-role .creds. The legacy `auth.conf` keeps working until
step 4.

```bash
aon auth render          # operator + account + users + render server.conf
aon creds --all          # emit ~/.aon/teams/<team>/creds/<role>.creds for every user
```

What landed:

- `~/.aon/nsc/` — engine-controlled NSC home (operator JWT, account
  JWT, user JWTs, signing keys).
- `~/.aon/teams/<team>/nats/nats-server.conf` — rendered with
  `operator: …` + `system_account: …` + `resolver: { type: full,
  dir: /etc/nats/runtime/resolver }`.
- `~/.aon/teams/<team>/nats/resolver/<team-account-id>.jwt` — team
  account JWT for the resolver to load on boot.
- `~/.aon/teams/<team>/creds/*.creds` — one file per role
  (sysadmin + every roster role). chmod 600.

Sanity:

```bash
aon doctor               # rendered nats-server.conf + resolver dir present
```

---

## 2. Distribute per-role .creds to joiners (~30s)

Each joiner's `<role>.creds` file must reach their box before the
cutover. Use the existing secret channel — same operational
constraints as today's password distribution.

For each role:

```bash
aon creds <role>         # confirms one file at ~/.aon/teams/<team>/creds/<role>.creds
# scp / 1Password / waiting-room admit (when that ships) → joiner
```

Joiner replaces their local .creds (operators with multi-role boxes:
update each).

Wait for ack from every joiner before proceeding.

---

## 3. Brief downtime window — swap config + restart (target <60s)

This is the only destructive step. Coordinate so every joiner is
ready to re-pub-handshake immediately after.

```bash
# 3a — stop the running nats container (still on legacy auth)
aon nats down

# 3b — boot under the new config (already rendered in step 1)
aon nats up

# 3c — bootstrap streams under sysadmin .creds
aon bootstrap            # idempotent; no-ops if streams already exist
```

Expected log on `aon nats up`: `"Server is ready"` within ~5s of
container start. If the resolver dir is empty or the rendered conf
has unsubstituted placeholders, the server will refuse to start —
fix and retry (`aon doctor` will say which).

Verified end-to-end timing: the same sequence runs in **<10 seconds**
in `scripts/nsc-smoke/run-smoke.sh` Phase C against a fixture team.
A real substrate hits ~30s with healthcheck delays included.

---

## 4. Joiner reconnect (in parallel with step 3)

Each joiner runs:

```bash
# Confirm new .creds in place
ls -la ~/.aon/teams/<team>/creds/<role>.creds

# Probe handshake
nats --server <url> --creds ~/.aon/teams/<team>/creds/<role>.creds rtt

# Reconnect Claude session if running
# (claude hooks pick up creds via aon resolve-env on next tool call)
```

If the rtt fails:

- check `aon nats status` (operator) — server up?
- check the .creds file exists and is non-empty (joiner)
- `aon doctor` (joiner) — flags missing creds or stale env

---

## 5. Soak window (24–72h)

Keep the legacy `auth.conf` + `.passwords` files on disk for rollback.
Don't yet wire any new role onboarding to JWT — let the existing
roster shake out first.

Monitor for:
- handshake failures in `aon nats logs`
- `permissions violation` errors that didn't appear pre-cutover
  (would mean a claim translation drift)
- joiner reports of stale connections

---

## 6. Post-soak cleanup

After the soak period passes without auth-related incident:

```bash
# Remove legacy state files
rm -f ~/.aon/teams/<team>/nats/auth.conf
rm -f ~/.aon/teams/<team>/nats/auth.conf.example
rm -f ~/.aon/teams/<team>/.passwords

# Doctor confirms cleanup
aon doctor               # legacy warns drop off
```

The `aon auth set-passwords` deprecation stub is kept for one more
release cycle, then deleted.

---

## Rollback (within soak window)

If the JWT path misbehaves and rollback is needed:

```bash
# 1. Stop NATS
aon nats down

# 2. Revert nats-server.conf to the legacy include
#    (git history has the pre-cutover version — last commit before
#    nsc-jwt S2)
git -C ~/Repos/team-<name> checkout HEAD~10 -- nats/nats-server.conf

# 3. Bring NATS back up
aon nats up

# 4. Joiners rotate their creds back to the legacy passwords
#    (still in ~/.aon/teams/<team>/.passwords).
```

After rollback, file an incident card describing what failed; do not
re-attempt the cutover until the root cause is understood.

---

## Acceptance

- Substrate-down to substrate-up window: <60s observed.
- Every roster role connects with .creds and round-trips a probe pub.
- `aon doctor` is clean (no bad: messages).
- No joiner has stale `.password` content under
  `~/.aon/teams/<team>/creds/`.
- Smoke `scripts/nsc-smoke/run-smoke.sh` passes 50/50 from this host.

---

## References

- `.tasks/nsc-jwt-migration.md` — migration plan (S2 cutover scope).
- `docs/runbooks/nsc-rotate-user.md` — per-user rotation after cutover.
- `scripts/nsc-smoke/run-smoke.sh` Phase C — production-shape template
  E2E proof (rendered conf + bootstrap.sh under --creds).
- `scripts/nsc-smoke/run-smoke.sh` Phase D — revoke-takes-effect proof.
