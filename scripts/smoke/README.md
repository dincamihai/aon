# Smoke tests

Lightweight regression harness for the team-alpha NATS substrate.

These scripts capture every smoke check that's been run by hand during build,
so the same checks can be re-run after any change without re-typing or
re-thinking. **Run after every change to `nats/auth.conf`, `nats-server.conf`,
`bootstrap.sh`, or `onboard.sh`.**

## Prerequisites

Auth model v2: NSC-signed JWTs (.tasks/nsc-jwt-migration.md). Each role
authenticates with its own `.creds` file.

- Stack running: `aon nats up` (or `docker compose up -d nats`)
- NSC artifacts minted + nats-server.conf rendered: `aon auth render`
- Per-role .creds emitted: `aon creds --all`
- Streams + KV bootstrapped: `aon bootstrap`
  (or `NATS_ADMIN_CREDS=<sysadmin.creds> bash scripts/bootstrap.sh`)

The smoke harness reads `.creds` from `$SMOKE_CREDS_DIR` (default
`~/.aon/teams/<team>/creds/`). Override per-env via `SMOKE_CREDS_DIR=…`.

## Files

| script | what it asserts |
|---|---|
| `_lib.sh` | shared helpers: `assert_pub_ok`, `assert_pub_denied`, `assert_sub_ok`, `summary` |
| `01-auth-boundaries.sh` | every role × representative allowed/denied subject — production vs learning lanes, manager-can't-post-results, specialists-can't-claim-out-of-domain |
| `02-onboard-roundtrip.sh` | `onboard.sh` works end-to-end for all six roles: env validation, auth, handshake event, KV load write, terminal banner |
| `03-substrate-health.sh` | streams (TASKS, LEARNING, RESULTS, EVENTS, AUDIT) exist with expected retention; KV `team-state` seeded; AUDIT mirrors keep up |
| `run-all.sh` | runs all `0*.sh` in order; non-zero exit if any test fails |
| `04-liveness.sh` | stuck-flow detection: pending backlog w/ no active workers, stale active loads, work-queue with no consumers |
| `05-claim-race.sh.todo` | **TODO** — concurrent claimers, only one wins (current impl segfaulted; needs rewrite using simpler stream peek) |
| `06-priority-change.sh` | re-publish of same task at higher priority; both versions in AUDIT for human reconstruction |
| `07-human-in-loop.sh` | manager-controlled `policy.delegated` KV; non-managers cannot flip; companion `state.policy` event for live subscribers |

## Usage

```bash
bash scripts/smoke/run-all.sh
```

Output: per-test pass/fail bullets, final summary `N pass, M fail, K skip`,
overall banner.

## Adding a test

1. Drop a new `0N-<topic>.sh` in this dir.
2. Source `_lib.sh`, use the assert helpers, end with `summary`.
3. Add a row to the table above.
4. `chmod +x` the script.

Don't add tests that rely on multi-second timing — keep each script <5s.

## When this fires false negatives

- **`Permissions Violation` showing as success on `subscribe`**: NATS sends
  perm errors asynchronously on subscribe; `assert_sub_denied` greps stderr
  for the violation. If it's reordered, falls through. Use pub-side asserts
  whenever possible — they're synchronous.
- **`request_time` warnings from `server check connection`**: ignore — we
  use `nats rtt` instead which doesn't require `$SYS` perms.

## When this is NOT enough

This harness validates the *substrate*. It does NOT validate:

- whether a Claude agent obeys its role prompt (covered by card 65 sim)
- whether AUDIT retention catches up under load
- whether KV history depth is sufficient for review workflows
- network reachability over corp VPN (different ground truth — see
  `docs/network.md` once card 70 lands)
