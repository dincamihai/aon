---
column: Backlog
created: 2026-04-28
updated: 2026-04-28
order: 95
priority: normal
supersedes_partial: aon join-link flow
superseded_by_partial: waiting-room-admit
parent: onboarding-overhaul
---

# Streamline `aon join` — joiner-side post-admit polish

**Pivot (2026-04-28):** team direction shifted to waiting-room admit
(see `.tasks/waiting-room-admit.md`). That card replaces the
`aon join-link TOKEN BITS` flow with admin live-approval. This card
now scopes only **post-admit joiner-side polish** + admin-side
team-init quality-of-life.

End state (joiner box, after `aon connect <url>` + admit):

```bash
# joiner box, post-admit
aon connect wss://team-url   # waiting-room flow handles role + creds
claude                       # agent self-bootstraps MCP / prompts
```

## Sub-tasks (ELI5 cave-man)

### 1. No URL prompt ✅ DONE (59127f2)

Now: aon ask "where NATS server?" you press Enter, it write
`wss://nats.example.com` (fake address). Bad.
Fix: aon look in saved env file first. If saved → use saved. No ask.
No bug.

**Shipped**: empty Enter keeps prior URL; placeholder URLs refused.

### 2. Auto-detect work-repo ✅ DONE

Now: type `aon join mihai /Users/mid/Repos/saas`. Long.
Fix: if you already inside saas folder (cwd is git repo), aon use
that. Just type `aon join mihai`. Done.

**Shipped**: `aon join <role>` without 2nd arg uses cwd's git
toplevel; refuses if cwd is the team repo.

### 3. Auto-detect role ⊘ SUPERSEDED by waiting-room-admit

Now: must say which role you want (mihai? vahid?).
Fix: if team has 1 empty seat → take that seat. Type `aon join`.
Done.

**Superseded**: waiting-room flips this — admin picks role at admit
time, joiner doesn't specify. Joiner can still suggest preferred
role in the connect-request payload.

### 4. Defer MCP install

Now: `aon join` write `.mcp.json` file (tells Claude which tools to
load) with `aon` + `aon-board` keys via portable `aon mcp-server`
launcher.
Fix: skip auto-write. Agent first turn see no `.mcp.json`, say
"human, run `aon mcp install`". Human run. Then restart Claude.
Detach install from join.

### 5. Defer prompt render

Now: `aon join` write `mihai.md`, `vahid.md` files. Mostly same
content. Wasted.
Fix: don't write files. MCP server build prompt fresh when agent
ask `get_role_brief()`. One source of truth.

### 6. CLAUDE.md = bootstrap manifesto

Now: CLAUDE.md has long block of rules.
Fix: keep tiny. Just say "you aon agent on team `<team>`. Read MCP
for full rules via `get_role_brief()`. If MCP missing, run
`aon mcp install`." Cave-man manifesto. Short.

### 7. Auto-start NATS

Now: NATS not running → `aon join` fail probe. Human must run
`aon nats up`.
Fix: aon detect "no NATS running" → auto-start. One step less.

### 8. ACL self-test

Now: aon probe one event. If pass, ✓. But maybe agent allowed
publish to channel A but not B. Don't know until break.
Fix: aon try every channel agent supposed to use. Print which work,
which fail. No surprise later.

### 9. Gitignore patches ✅ DONE

Now: `.mcp.json` per-repo. Could leak to git commit. Bad if has
paths/secrets.
Fix: aon add `.mcp.json` to `.gitignore` line. Auto. No accidental
commit.

**Shipped**: `_aon_install_repo_mcp` appends `.mcp.json` to
`<work_repo>/.gitignore` when missing. Idempotent.

### 10. Welcome card

Now: `aon join` print "✓ done". Agent ask "what now?".
Fix: print big block: "you mihai. you can publish to: X, Y. you can
DM peer with: `aon pub agents.<peer>.inbox <msg>`. start session:
`claude`". Cheat sheet on screen.

### 11. Pre-seed task card

Now: agent first turn idle. Wait for human.
Fix: aon drop `.tasks/welcome-mihai.md` with "step 1: ping vahid.
step 2: claim a task. step 3: start monitor." Agent has work
day-one.

### 12. Two commands: `aon up` (admin) + `aon connect` (joiner)

Now: admin runs `aon init`, `aon add-role`, `aon onboard` per joiner,
shares token+bits. Joiner runs `aon join-link`. Many step.
Fix split (post waiting-room):
- **Admin**: `aon up` = `init` + `add-role` (per role from aon.toml)
  + `nats up` + URL share. Idempotent. No per-joiner work.
- **Joiner**: `aon connect <url>` (from waiting-room card). Block,
  decrypt creds, write env, probe, welcome.

Two commands total. Each side runs one. No tokens shared.

## Order to do (post-pivot)

1. **Done already**: #1 URL prompt, #9 gitignore, #2 auto-detect
   repo (last one shipped uncommitted on worker branch).
2. **Wait for waiting-room**: #3 superseded; #12 depends on `aon
   connect` landing.
3. **Independent now** (can ship before waiting-room): #4 defer MCP
   install, #5 defer prompt render, #6 CLAUDE.md manifesto. All
   joiner-side post-bootstrap polish, agnostic of how creds arrive.
   Coordinate with `aon` MCP `get_role_brief` composer.
4. **Verify layer**: #7 auto-start NATS (admin side, independent),
   #8 ACL self-test (joiner-side post-admit, independent).
5. **UX layer**: #10 welcome card, #11 task seed. Independent.

## Dependencies

- `waiting-room-admit` (.tasks/waiting-room-admit.md): supersedes #3
  + reshapes #12. Must land before this card's #12 capstone.
- `nsc-jwt-migration` (.tasks/nsc-jwt-migration.md): waiting-room
  needs JWT-based creds for clean encrypt/revoke.

## Out of scope

- Joiner provisioning crypto (handled by waiting-room-admit).
- NSC/JWT migration itself.
- Renaming `team-alpha` → real team name (already shipped d54f794).
- Multi-team-per-host scenarios.

## Acceptance (post-pivot)

- Admin: `aon up` once, share URL.
- Joiner: `aon connect <url>` + admit handshake → working agent in
  ≤ 2 minutes from URL receipt.
- Re-running either command is a no-op when already set up.
- Zero prompts during normal `aon up` flow.
- One screenful of welcome output explains how to message a peer
  and how to start work.
