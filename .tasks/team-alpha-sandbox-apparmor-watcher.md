---
column: Backlog
created: 2026-04-27
order: 229
priority: low
parent: team-alpha-sandbox-apparmor-sync-generator
depends_on: team-alpha-sandbox-apparmor-sync-generator
---

# Card 229 — Sandbox: auto-resync AppArmor on repo clone (host watcher)

Port from `~/Repos/ai-fleet-harness/.tasks/sandbox-apparmor-watcher.md`.

`team-alpha apparmor sync` is manual (Card 228). After cloning a
new repo, must remember to run it. Window where new repo is
allowed (blocklist) or invisible (allowlist) while reality and
policy disagree.

## Deliverables

- `scripts/host/com.team-alpha.apparmor-watcher.plist` — macOS
  LaunchAgent with `WatchPaths = [$HOME/Repos]`.
- `scripts/host/apparmor-watcher.sh` — debounced wrapper around
  `team-alpha apparmor sync --reload` (5s default debounce).
- `team-alpha apparmor watch install|uninstall` — bootstrap.
- `docs/sandbox.md` brief section.

## Acceptance

- `team-alpha apparmor watch install` registers via `launchctl`.
- `git clone <new-repo> ~/Repos/new-thing` → within 10s,
  `~/.team-alpha/apparmor/worker` updated AND VM profile reloaded.
- `uninstall` removes cleanly.

## Risks

- macOS-only. Linux hosts need inotify variant — out of scope.
- LaunchAgent must not loop if sync writes update its own watch path.
- Debounce must absorb `git clone`'s atomic rename.

## Why low priority

Manual sync after a clone is one shell line.
