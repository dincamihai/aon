---
column: InReview
created: 2026-04-27
order: 225
priority: medium
parent: team-alpha-sandbox-arm-colima-apparmor
depends_on: team-alpha-sandbox-arm-colima-apparmor
---

> **Status (2026-04-27):** Shipped scripts + doctor command +
> VM smoke. Files:
>
> - `scripts/ensure-clone.sh` — hardlink clone via `git clone
>   --shared`, rewires `origin` → GitHub, `host` → file mount.
> - `scripts/worktree-claim.sh` — frontmatter `repo:` aware;
>   legacy single-repo fallback when absent.
> - `scripts/worktree-cleanup.sh` — `<slug>` and `--prune` modes.
> - `bin/team-alpha-doctor` — verifies repos root, known-repos
>   list, worker home writability, NATS token readability.
>
> All four scripts auto-detect repos root via `/etc/team-alpha/env`
> first, then scan `/Users/*/Repos` and `/home/*/Repos` (host
> UID does NOT match worker UID inside sandbox VM, so `$USER` is
> unreliable).
>
> VM smoke (ta-worker-raj, AppArmor enforce):
>
> - `team-alpha-doctor` → PASS (39 repos, ai-over-nats present,
>   /work/workers/raj writable, NATS token readable).
> - `ensure-clone.sh ai-over-nats` → hardlinked clone at
>   /work/workers/raj/ai-over-nats, alternates point to host
>   mount, `host` remote wired.
> - `git worktree add raj/test-slug` from `host/main` → branch
>   created, worktree owned by ta-worker-raj.
>
> **Not yet smoke-tested** (deferred — needs GitHub remote on
> the task-board repo): full claim race via
> `worktree-claim.sh <slug>` end-to-end (commits + pushes the
> column flip). Logic identical to fleet-harness `worktree-claim.sh`
> which is proven there. Will exercise once a card with `repo:
> ai-over-nats` frontmatter ships and the repo gets pushed to
> GitHub.

# Card 225 — Sandbox: multi-repo worktree flow inside the VM

Port from `~/Repos/ai-fleet-harness/.tasks/sandbox-multirepo-worktree-flow.md`.

Sandbox VM mounts `~/Repos` from host **read-only**. Workers
cannot mutate host repos; they clone locally under
`/work/workers/<role>/` and operate on per-card git worktrees
branched off `origin/master` (or `main`). Code re-enters host only
via merged PRs.

## Goal

Worker on the sandbox VM, given a card whose frontmatter names a
repo, can:

1. Resolve repo → local clone path under own home.
2. Create the clone on first touch (hardlinked from
   `/Users/.../Repos/<repo>`, sub-second).
3. Run `worktree-claim.sh` against that clone — same atomic
   card-claim semantics as today.
4. Edit, push, open PR, run `worktree-cleanup.sh`.
5. Coord reads via per-user ACL (set up by Card 224).

## Deliverables

- `scripts/ensure-clone.sh` — idempotent local-clone bootstrap from
  read-only host mount via `git clone --shared` (hardlinks).
- `scripts/worktree-claim.sh` — read `repo:` frontmatter, call
  `ensure-clone.sh`, branch `<role>/<slug>` from `host/master`,
  land worktree at `/work/workers/<role>/<repo>.worktrees/<slug>/`.
- `scripts/onboard.sh` — pre-clone every entry from
  `[repos] known = [...]` into the worker's home on first run.
- Card frontmatter convention: optional `repo: <name>`. Cards
  without it fall back to legacy single-repo (CWD's git toplevel).
- Update worker prompt: "pick repo, ensure local clone, then claim
  worktree" instead of "cd into the project".
- `team-alpha doctor` — verifies every known repo is mounted at
  `$FLEET_REPOS_ROOT`.

## Acceptance

- New worker, fresh VM: `bash scripts/onboard.sh worker` clones all
  known repos in <5s total.
- Card with `repo: ccc` claimed by maya → worktree appears at
  `/work/workers/maya/ccc.worktrees/<slug>/`, branch `maya/<slug>`,
  origin = GitHub URL inherited from host clone.
- `git -C /work/workers/maya/ccc remote -v` shows `origin` (GitHub)
  + `host` (file mount).
- Cleanup deletes worktree dir + branch ref. No orphan branches.
