---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 228
priority: medium
parent: team-alpha-sandbox-personal-apparmor-overrides
depends_on: team-alpha-sandbox-personal-apparmor-overrides
---

> **Status (2026-04-27, smoke green):** `bin/team-alpha-apparmor`
> umbrella with `sync` subcommand shipped. Subcommand contract:
>
> - `team-alpha-apparmor sync`         — write override files.
> - `team-alpha-apparmor sync --show`  — classify only, no write.
> - `team-alpha-apparmor sync --reload`— write + push to VM via
>   `colima ssh ... | sudo tee ...` (mount-independent), then
>   trigger `reload-apparmor.sh`.
>
> Policy at `~/.team-alpha/apparmor/policy.toml` (auto-stub on
> first run): `[worker]` with `allow_orgs`, `deny_orgs`,
> `deny_no_remote`, `default`. `[coord]` mirrors worker unless
> non-empty.
>
> Idempotence: file body compared modulo timestamp line.
>
> End-to-end smoke (host → VM):
>
> - 16 repos in exasol/exasol-labs → ALLOW (no rule emitted).
> - 11 repos in dincamihai/no-remote → DENY rules emitted.
> - `--reload` pipes both kinds over SSH, re-parses profiles
>   in VM (no host mount dependency).
> - `aa-exec -p team-alpha-worker` from ta-worker-raj:
>   read `/Users/mid/Repos/ai-over-nats/` → denied.
>   read `/Users/mid/Repos/ccc/` → allowed.
>
> `watch` subcommand stub returns "not yet implemented (Card 229)".

# Card 228 — `team-alpha apparmor sync` — generate personal override from repo remotes

Port from `~/Repos/ai-fleet-harness/.tasks/sandbox-apparmor-sync-generator.md`.

Hand-written `~/.team-alpha/apparmor/worker` is brittle. Every new
repo cloned to `~/Repos` requires manual edit, or it leaks through
(no deny rule = falls through to shared profile's `/Users/** r,`).

## Goal

```bash
team-alpha apparmor sync --policy ~/.team-alpha/apparmor/policy.toml
team-alpha apparmor sync --reload   # also reload-apparmor.sh in VM
```

Walk `~/Repos`, classify each entry by `git remote get-url origin`,
bucket by org, apply policy, rewrite
`~/.team-alpha/apparmor/{base,coord,worker}`. Idempotent —
diff-report on stdout, exit 0 even when nothing changed.

## Policy file (`~/.team-alpha/apparmor/policy.toml`)

```toml
[worker]
allow_orgs     = ["exasol", "exasol-labs"]
deny_orgs      = ["dincamihai"]
deny_no_remote = true   # repos without origin → deny
default        = "deny" # or "allow"

[coord]   # optional; defaults to mirror of [worker]
```

## Deliverables

- `bin/team-alpha apparmor sync [--policy] [--reload] [--dry-run]`.
- Repo-classification logic in `worker-agent/sandbox/apparmor/`.
- Diff-report formatter.
- `docs/sandbox.md` updated.

## Acceptance

- Sync on a host with 10 repos, mixed orgs → emits the expected
  deny/allow lines, `--dry-run` shows the diff, real run rewrites
  files atomically.
- `--reload` invokes `reload-apparmor.sh` over `colima ssh`.
- New repo cloned, sync re-run → diff shows the new entry only.
