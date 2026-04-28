---
column: Backlog
created: 2026-04-28
order: 90
priority: normal
---

# Streamline `aon join` — make onboarding cave-man simple

Now: many steps, many files written, many bugs (URL clobber, prompt
drift, MCP global pollution). Goal: one command, one cheat sheet, no
surprise.

End state:

```bash
cd ~/Repos/saas
aon up mihai     # do everything. idempotent. safe to re-run.
claude           # start session. agent self-bootstrap from here.
```

## Sub-tasks (ELI5 cave-man)

### 1. No URL prompt ✅ DONE (59127f2)

Now: aon ask "where NATS server?" you press Enter, it write
`wss://nats.example.com` (fake address). Bad.
Fix: aon look in saved env file first. If saved → use saved. No ask.
No bug.

**Shipped**: empty Enter keeps prior URL; placeholder URLs refused.

### 2. Auto-detect work-repo

Now: type `aon join mihai /Users/mid/Repos/saas`. Long.
Fix: if you already inside saas folder (cwd is git repo), aon use
that. Just type `aon join mihai`. Done.

### 3. Auto-detect role

Now: must say which role you want (mihai? vahid?).
Fix: if team has 1 empty seat → take that seat. Type `aon join`.
Done.

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

### 9. Gitignore patches

Now: `.mcp.json` per-repo. Could leak to git commit. Bad if has
paths/secrets.
Fix: aon add `.mcp.json` to `.gitignore` line. Auto. No accidental
commit.

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

### 12. Single `aon up`

Now: must run `aon init`, `aon add-role`, `aon onboard`, `aon join`.
Many step. Forget order → break.
Fix: one command `aon up mihai`. Run again, no harm. Run on fresh
team or existing — same. One command remember.

## Order to do

1. **Quick wins first** (low risk, high payoff): #1 URL prompt, #9
   gitignore, #2 auto-detect repo. Each one PR.
2. **Defers** (need MCP-side work too): #4, #5, #6 — coordinate with
   `team-alpha-mcp` `get_role_brief` composer.
3. **Verify layer**: #7 auto-start NATS, #8 ACL self-test. Improves
   confidence at end of `aon up`.
4. **UX layer**: #10 welcome card, #11 task seed.
5. **Capstone**: #12 `aon up` collapses everything.

## Out of scope

- NSC/JWT migration (separate card).
- Renaming `team-alpha` → real team name in MCP server name.
- Multi-team-per-host scenarios.

## Acceptance

- New operator can clone a team-aon repo, run `aon up <role>`,
  then `claude`, and have a working agent within 2 minutes.
- Re-running `aon up` is a no-op when already set up.
- Zero prompts during normal `aon up` flow.
- One screenful of welcome output explains how to message a peer
  and how to start work.
