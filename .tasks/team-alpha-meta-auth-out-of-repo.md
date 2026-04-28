---
column: Backlog
created: 2026-04-28
order: 1080
priority: high
parent: team-alpha-team-portability
depends_on: team-alpha-meta-aon-registry
---

# Card — Move auth.conf + .passwords out of the team-aon repo

## Context

Today `aon onboard` writes `nats/auth.conf` and `nats/.passwords` into the team-aon git repo. This caused the "saas vs saas-john" bug live in this codebase: two worktrees diverged (onboard ran from `~/Repos/saas-john` and wrote auth.conf there, but the running NATS container mounted `~/Repos/saas/nats/auth.conf`), so newly onboarded roles were rejected at handshake even though the operator did everything "right." A full debugging session went into chasing the mismatch.

Root cause: the team-aon repo conflates two concerns:

- **Versionable config**: `aon.toml`, `.tasks/`, `agent-prompts/` (shared, safe to commit, identical across worktrees by virtue of being git-tracked).
- **Secret runtime state**: `auth.conf` (plain-text role passwords), `.passwords`. These should never be committed and don't belong in a multi-worktree workflow.

`auth.conf` is currently committed today — anyone with read access to the team-aon repo sees every role's password. Moving it out fixes a real security issue *and* removes the multi-worktree drift class entirely.

Joiners are unaffected: they never had `auth.conf` (only their own role's password file in `~/.aon/teams/<team>/creds/<role>.password`). The token already gives them their password and `aon join-link` writes it.

## What changes

### New layout under `~/.aon/teams/<team>/`

```
~/.aon/teams/<team>/
  repo/                    # team-aon git checkout (unchanged)
  creds/                   # joiner-side per-role password (existing)
    <role>.password
    <role>.env
  auth.conf                # NEW — operator-side, runtime only
  .passwords               # NEW — operator-side, runtime only
```

### Docker compose mount

- **Before:** `$AON_TEAM_DIR/nats/auth.conf:/etc/nats/auth.conf:ro`
- **After:** `~/.aon/teams/<team>/auth.conf:/etc/nats/auth.conf:ro`

Stable host path; identical regardless of which worktree the operator runs commands from. `templates/docker-compose.yml.tmpl` accepts `@AUTH_CONF_PATH@`.

### Commands to update

| Command | Change |
|---|---|
| `cmd_auth_render` | Write `auth.conf` + `auth.conf.example` to `~/.aon/teams/<team>/`, not `$AON_TEAM_DIR/nats/`. |
| `cmd_auth_set_passwords` | Write `.passwords` to `~/.aon/teams/<team>/`. Substitute placeholders in the new auth.conf path. |
| `cmd_creds` / `cmd_creds_all` | Read `.passwords` from new path. |
| `cmd_onboard` step 3 | No more `git add nats/auth.conf` — file isn't in repo anymore. |
| `cmd_onboard` step 5 | `_aon_nats_find_container` matches against the new mount source path. |
| `cmd_nats_up\|down\|logs\|status` | Same. Mount source in compose template uses `~/.aon/teams/<team>/auth.conf`. |
| `cmd_doctor` | Verify presence of `~/.aon/teams/<team>/auth.conf` + `.passwords` instead of repo paths. |

### Files NOT changed

- `nats/nats-server.conf` — stays in repo (no secrets; references auth.conf by container path `/etc/nats/auth.conf` which is mount-target, host-side change is invisible to the file's contents).
- `aon.toml`, `.tasks/`, `agent-prompts/`, `agents/`, `hooks/` — unchanged.
- Joiner-side `~/.aon/teams/<team>/creds/<role>.{password,env}` — unchanged.

### `.gitignore` in team-aon repo

Add:

```
nats/auth.conf
nats/.passwords
nats/auth.conf.example
```

(`auth.conf.example` also moves out — it's a render artifact that's reproducible from `aon.toml`, so it doesn't need a versioned copy.)

### Migration helper for existing repos

```bash
aon auth migrate    # copies $AON_TEAM_DIR/nats/auth.conf → ~/.aon/teams/<team>/auth.conf
                    # copies .passwords too (chmod 600)
                    # prints `git rm --cached nats/auth.conf nats/.passwords nats/auth.conf.example`
                    # for the operator to commit
```

The operator runs the `git rm --cached` themselves to keep the audit trail clean. The migrate command is idempotent (skip if target exists, warn on size diff).

### Security wins

1. Plain-text role passwords no longer in git history (going forward; old commits still leak — separate clean-up).
2. Auth.conf can't drift across worktrees — there's only one canonical file.
3. Joiners never see the operator's auth.conf (they only get their own role password via the token, same as today).

## Verification

1. `aon auth render` → writes to `~/.aon/teams/team-alpha/auth.conf`, NOT `$AON_TEAM_DIR/nats/`.
2. `aon nats up` → compose mounts the new host path; container starts healthy.
3. `aon onboard <role> <bits>` from any worktree of the team-aon repo → same `~/.aon/teams/team-alpha/auth.conf` updated, same SIGHUP target found.
4. `docker exec <container> cat /etc/nats/auth.conf | grep <role>` → role present.
5. `git status` inside the team-aon repo → no auth.conf, no .passwords (clean tree post-migrate).
6. Two worktrees of the team-aon repo (e.g. `saas` + `saas-john`) → `aon onboard` from either updates the SAME auth.conf, joiner's handshake passes regardless of which worktree the operator used.

## Out of scope (separate cards)

- NSC JWT auth (Card 247) — different auth backend entirely. This card just reorganizes filesystem layout for the existing user/password auth.
- Multi-operator failover (under discussion). Each operator on a separate host has their own `~/.aon/teams/<team>/auth.conf`. Sync mechanism (NATS-replicated or via the team-aon repo with encryption) is a separate design problem.
- Bot-driven joiner onboarding over NATS (chicken-and-egg with auth — needs design before implementation).
