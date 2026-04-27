---
column: Backlog
created: 2026-04-27
order: 1040
priority: medium
---

# Ship Claude Code skills for aon admin + joiner onboarding

## Problem

Today's Vahid trial-test surfaced a recurring class of friction: the
operator (and joiner) has to remember a multi-step shell sequence each
time someone joins, switches domain, rotates a tunnel URL, or recovers
from a stale `.claude/settings.json`. Every step is documented in the
README §1–§2.5 runbooks and on individual task cards, but the cost of
**recalling + executing** the right sequence under time pressure is
high — so people skip steps, hit known-symptom bugs (`→` literal arg,
operator path leak, `https://` vs `wss://`), and burn cycles.

Claude Code skills (`/skill-creator` + the `~/.claude/skills/` /
project-level skills/ pattern) are designed exactly for this: a
trigger description + step-by-step procedure that auto-loads when the
operator says the right thing.

## Scope

Ship a curated set of `aon`-flavored skills inside the ai-over-nats
engine repo so they ride along with `pipx install --editable
~/Repos/ai-over-nats` and any per-team clone. Two audiences:

### Admin skills (operator side)

1. **`aon:add-role`** — guided role-onboarding workflow.
   Trigger: "add a role", "onboard <name>", "trial test".
   Sequence:
   - `aon add-role <name> <kind> <domain>`
   - `aon prompts render && aon auth render && aon auth set-passwords`
   - `aon creds <name>` (warns if `<name>` already shipped)
   - `aon nats up` to reload
   - `aon doctor`
   - Compose the out-of-band share block (repo URL, password content,
     NATS URL, role name) — formatted for paste-into-1Password.
2. **`aon:rotate-tunnel`** — handle ephemeral cloudflared URL changes.
   Trigger: "tunnel restarted", "trycloudflare URL changed", "joiner
   can't connect".
   Sequence:
   - `pgrep -af cloudflared` to confirm tunnel up.
   - Read latest URL from `/tmp/cloudflared-*.log`.
   - `sed` patch `aon.toml` `[nats] ws_url`.
   - Commit + push.
   - DM joiners to `git pull && rm ~/.team-alpha/<role>.env && aon
     join <role> <work-repo>`.
3. **`aon:diagnose-handshake`** — when `aon join` reports NATS
   handshake failed.
   Trigger: "NATS handshake failed", "Authorization Violation",
   "joiner can't connect".
   Sequence: walk the diagnostic tree from PR #25 README §2 callout —
   container running? auth.conf has user? local nats CLI auth as user
   passes? URL scheme `wss://`? password match? Output a single-line
   verdict + the one fix command.
4. **`aon:trial-test`** — full operator + joiner runbook for the
   §2.5 mid-cycle joiner case. Trigger: "trial test", "Vahid", "try
   <name> on the team". Composes `aon:add-role` + share-block + first
   `aon monitor <role>` pane.
5. **`aon:vahid-recovery`** (or generalized `aon:settings-recovery`)
   — fix stale operator-path hooks in joiner's
   `<work-repo>/.claude/settings.json`. Trigger: "hook commands point
   at /Users/mid", "operator path in settings", "settings.json broke".
   Sequence: surgical `jq` strip of operator-path hook entries
   (preserves theme/model/permissions) + `aon join` re-run.

### Onboarding skills (joiner side)

6. **`aon:join`** — first-time joiner walkthrough. Trigger: "I'm
   joining a team", "set me up", "aon join". Sequence:
   - Engine prereqs check (claude, nats, jq, python3, pipx).
   - Engine install via pipx editable.
   - Clone team-aon repo, cd into it.
   - Place password at `~/.team-alpha/<role>.password` (chmod 600)
     from the operator's share block.
   - `aon join <role> <work-repo>` (with absolute path).
   - Verify NATS handshake green.
   - `cd <work-repo> && claude`.
   - Run **first-turn discipline**: open Monitor + `a2a_inbox()` +
     wait for instruction (suppress global resume-prompt block).
7. **`aon:first-turn`** — what to do once claude boots. Trigger:
   "first turn", "I just joined", "onboard me as <role>". Reminds
   about resume-prompt suppression, `a2a_inbox`, MCP tools, role
   brief, cycle loop.
8. **`aon:monitor`** — operator-or-joiner observability quick start.
   Trigger: "monitor my role", "watch the team", "aon monitor".
   `aon monitor <role>` in a separate pane; explains what each
   subject category means.

## Where the skills live

Two viable locations:

a. **Engine-level**: `~/Repos/ai-over-nats/skills/aon/*.md`. Ships
   with the engine clone. Joiners get them via `pipx install
   --editable`. Operator gets them on the host clone.
b. **User-level**: `~/.claude/skills/aon/*.md`. Survives across
   projects but doesn't auto-distribute with the engine.

Recommend (a). Symlink or document copy-into-`~/.claude/skills/` for
users who want global access. Engine repo becomes single source of
truth — `git pull` updates the procedure for everyone.

## Skill file format

Per `/skill-creator` convention each skill is a markdown file with:

```markdown
---
description: <when to trigger — first sentence is what the model matches on>
---

# <Skill Name>

<imperative procedure: numbered steps, exact commands, decision
branches for common error states>
```

Keep skills imperative + specific. No prose context; reference task
cards / README sections for theory.

## Acceptance

- [ ] `skills/aon/` directory exists in the engine repo with the 8
      skills above (or a sliced subset agreed on the card).
- [ ] Each skill has a sharp `description` so triggering is reliable
      (no false positives on unrelated prompts).
- [ ] Every command in every skill is copy-pasteable as-is —
      no `<role>` placeholders left where a real value should be
      substituted at trigger time.
- [ ] README §1–§2.5 add a "Skills" subsection pointing at
      `skills/aon/` and listing trigger phrases.
- [ ] Operator runs through `/aon:add-role` with a fresh role and
      reaches "joiner ready to connect" in <2 min, no manual recall
      of step ordering.
- [ ] Joiner runs through `/aon:join` from a clean box and reaches
      `claude` boot with all environment correct in <5 min.
- [ ] `/aon:diagnose-handshake` correctly identifies the four
      common failure modes (stale auth, scheme typo, dead tunnel,
      password mismatch) on synthetic test cases.

## Non-goals

- Replacing the README. Skills are entry points; README stays the
  long-form reference.
- General-purpose claude skills (review, debug, etc.). This card is
  scoped to **aon-flavored** workflows only.
- Skill-marketplace / sharing across teams. Out of scope until the
  curated set proves useful internally.

## Triggered by

- 2026-04-27 Vahid trial onboarding. Issues hit in sequence:
  (1) `aon add-role vahid generalist backend` produced an isolated
      domain namespace — captured in
      `team-alpha-roster-multi-skill-schema.md`.
  (2) `→` glyph copy-paste created a stray password file — fixable
      with a friendlier README + a `aon:fix-arrow-file` recovery
      skill.
  (3) NATS container ran 5h on stale auth — `aon:diagnose-handshake`
      catches this in seconds.
  (4) trycloudflare URL rotated — `aon:rotate-tunnel` automates the
      DM + commit.
  (5) Operator-path hooks in joiner's settings — fixed in PR #26 +
      surfaced in `aon:settings-recovery`.

The skill set is essentially the union of all friction modes this
trial exposed, rotated 90° from "fix the bug" to "ship the
recovery".

## References

- README §1–§2.5 — the runbooks the skills compress.
- PR #25 — README friction fixes that the diagnose skill encodes.
- PR #26 — hooks install fix that retired one recovery path.
- `team-alpha-roster-multi-skill-schema.md` — schema-side
  improvement that complements the admin skills.
- Anthropic skill-creator docs (built-in `/skill-creator` skill in
  Claude Code) — format + triggering conventions.
