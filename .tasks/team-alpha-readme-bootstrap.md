---
column: Backlog
created: 2026-04-26
order: 218
---

# Card 218 — README.md: human bootstrap + join-working-group guide

**Sequencing:** write AFTER Card 220 (post-MVP delegate + SDK
container architecture) lands. Card 214's per-role-CLI shape was
deferred and superseded by 220 on 2026-04-26; the bootstrap story
should match the shipped architecture, not the abandoned plan.

## Why

A new human teammate (or future-Mihai) currently can't bootstrap
team-alpha without spelunking through cards 60, 210, 211, 213,
214 + the agent prompts + NATS config. Need a single README at
repo root that gets a person from clone → running maya → joining
the working group as an observer or active role.

## Spec — sections

1. **What is team-alpha** — one-paragraph pitch + link to MODEL.md
   for the substrate, and to the ADRs.
2. **Prereqs** — claude CLI, docker OR podman, NATS server access
   (or local nats-server), git, python3.
3. **Bootstrap NATS** — `scripts/nats-bootstrap.sh` or equivalent.
   ACL primer (link `MODEL.md` for substrate).
4. **Bootstrap roles** — mint per-role passwords / NSC creds,
   land them at `~/.team-alpha/<role>.password`. Reference
   `team-alpha-nsc-jwt-migration.md` if applicable.
5. **Run a worker** — `team-alpha-spawn priya --repo <name>
   --task <slug>` (post-214 spawn script). Show what the human
   sees, what NATS subjects light up.
6. **Run maya (dispatcher)** — same pattern, host or container.
7. **Drop a task card** — operator-side `mcp__team-alpha-board__create_task`
   call, expected dispatch flow, where to watch (`nats sub
   'agents.>' 'a2a.>' 'board.>'`).
8. **Join as observer** — read-only NATS user, `nats sub
   'AUDIT.>'`, board `done/` directory tail.
9. **Common ops** — kill a stuck worker, requeue a card, replay
   AUDIT, rotate creds.
10. **Troubleshooting** — top 5 known papercuts (defects 216, 217,
    container restart, ACL deny, MCP server not registering).
11. **Working group etiquette** — when to DM vs. board card, how
    to shape a card, naming conventions
    (`tb-<date>-<slug>`, `worker/<role>/<slug>`).
12. **Pointers** — MODEL.md, ADRs, agent prompts, key cards
    (60/210/213/214).

## Files

- `README.md` — repo root, ~250-400 lines, walkthrough style.
- `docs/joining.md` — short version (1 page) for casual observers.
- (optional) `docs/diagrams/team-alpha-overview.svg` — block
  diagram of substrate + roles + board.

## Acceptance

- [ ] Fresh-clone walkthrough on a clean Mac brings up maya +
      one worker container + lands one tb-card → completion in
      under 30 minutes following only the README.
- [ ] No mandatory step requires reading ADRs or cards (those are
      "see also").
- [ ] Sections renumber cleanly if a future card adds steps.
- [ ] Lints clean (markdown-lint, no broken intra-repo links).

## Out of scope

- Multi-host deployment guide (single-host only for v1).
- Production-ops runbook (separate doc when team-alpha leaves
  simulation).
- Onboarding video / screencast.

## Refs

- Card 60 — onboard hooks (paste-friendly first-turn).
- Card 210 — session hooks.
- Card 213 — runtime task board.
- Card 214 — worker containerization (sequencing dependency).
- MODEL.md — substrate.
