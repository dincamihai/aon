---
column: Backlog
created: 2026-04-28
order: 52
priority: high
parent: nsc-jwt-migration
---

# `aon onboard` step 7/8 commits into `$HOME/.git` if team repo isn't a git repo

`cmd_onboard` step 7/8 runs:

```bash
git -C "$AON_TEAM_DIR" add -A
git -C "$AON_TEAM_DIR" commit -m "Onboard $name ($kind/$domain)"
git -C "$AON_TEAM_DIR" push
```

If `$AON_TEAM_DIR` (e.g. `~/Repos/workers`) is not a git repo, `git`
walks up looking for `.git` and finds the operator's `~/.git` (a
dotfiles repo, an accidental `git init` from years ago, etc.).
`git add -A` from that found-repo's worktree (= $HOME) then tries to
stage **the entire home directory**:

```
warning: could not open directory 'Music/Music/': Operation not permitted
warning: could not open directory 'Pictures/Photos Library.photoslibrary/': Operation not permitted
warning: could not open directory 'Library/Application Support/CallHistoryTransactions/': Operation not permitted
... (~50 more macOS-protected dirs)
```

macOS TCC blocks the protected paths, but anything writeable in
$HOME (the workers repo files included) gets staged + committed
into the wrong repo. Bad outcome on operator's box.

## Repro

```
mkdir ~/Repos/foo                       # NOT a git repo
cd ~/Repos/foo
aon init && aon add-role admin manager fullstack
aon nats up
aon onboard sun manager fullstack
# step 7/8 commits to $HOME/.git if it exists
```

## Fix

In `cmd_onboard` step 7/8, **assert `$AON_TEAM_DIR/.git` exists
before any git mutation**. If absent:

- `aon_warn`: "team-aon repo at $AON_TEAM_DIR is not a git repo"
- `aon_info`: "skipping commit + push; init it with: git -C
  $AON_TEAM_DIR init"
- continue to step 8/8 (token emission still works without commit)

Same guard belongs on any other `aon` command that does
`git -C "$AON_TEAM_DIR" ...`. Audit candidates:

```
grep -n 'git -C "$AON_TEAM_DIR"' bin/aon
```

## Related: `aon init` should `git init` automatically

`aon init` already creates aon.toml, docker-compose.yml, nats/,
agent-prompts/ etc. Adding a `git init` (idempotent: skip if
`.git` already exists) gives every team-aon a proper repo from
the jump and avoids the walk-up trap entirely. Tradeoff: forces
git on operators who'd rather not. Probably fine — team-aon repos
are meant to be committed (`aon onboard` push step assumes it).

## Acceptance

- Fresh `aon init <new-team>` results in `$new-team/.git/` present.
- `aon onboard NAME [KIND] [DOMAIN]` from a non-git team-aon dir
  refuses git mutations, prints clear directive to `git init`.
- No commits ever land in `$HOME/.git` from aon flows.
- `aon doctor` adds a check: warn if `$AON_TEAM_DIR/.git` is
  absent.

## Out of scope

- Auto-creating GitHub remote (operator's choice; aon push falls
  back to "no remote — push manually").
- Cleaning up commits that have already landed in `$HOME/.git`
  for existing operators (manual `git reset` on their end).

## References

- `bin/aon` `cmd_onboard` (step 7/8 around line 1717).
- `aon-init-leaves-unrendered-nats-conf.md` (sibling init bug).
