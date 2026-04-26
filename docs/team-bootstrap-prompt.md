# Team-alpha bootstrap prompt (paste into fresh claude session)

> **How to use**: in `~/Repos/ai-over-nats`, start a fresh
> `claude` session and paste everything below the `--- COPY ---`
> line as your first message. Claude follows the runbook and
> walks you through configuring the team. You provide answers as
> the questionnaire fires; claude does the file edits, password
> rotations, and prints the distribution block per colleague.

--- COPY ---

You are bootstrapping team-alpha for a live multi-human session.
We are in `~/Repos/ai-over-nats`. The substrate is described in
`MODEL.md`. Tomorrow's session-onboarding doc is
`docs/team-session-runbook.md`. The current 5 worker roles are
`priya, raj, lin, sam, diego` (maya is simulation-only).

Today's job: take Mihai's real colleagues, gather signals about
each from his Obsidian vault and Jira, synthesize a persona per
colleague, customize the matching role's brief + skills, rotate
every NATS password, and emit per-colleague distribution blocks
Mihai can drop into 1Password.

You do this **interactively** — fire questions one block at a
time, wait for Mihai's answers, do the work, summarize, move on.
Don't try to do it all in one shot.

## Pre-flight (run before the questionnaire)

1. Read `nats/auth.conf` — confirm it has the 7 users
   (sysadmin, maya, raj, lin, sam, diego, priya, sys) all with
   `devpass` placeholders. If passwords already rotated, stop
   and ask Mihai how to proceed.
2. Run `docker compose ps nats` — confirm container is running.
   If not, ask Mihai to bring it up before continuing.
3. Read `scripts/agent-prompts/_common.md` and skim it. This
   block is inherited by every role brief; the per-role brief
   layers on top.
4. List the role briefs we'll customize:
   `ls scripts/agent-prompts/{priya,raj,lin,sam,diego}.md` and
   summarize each in one line so Mihai can confirm assignments.

## Step 1 — rotate every password

Run this exact block (macOS bash 3.2-safe, no `${var,,}`):

```bash
cp nats/auth.conf nats/auth.conf.bak.$(date +%s)
: > /tmp/team-alpha-passwords.txt
chmod 600 /tmp/team-alpha-passwords.txt
for who in sysadmin maya raj lin sam diego priya sys; do
  pw=$(openssl rand -hex 24)
  # Replace ONLY the devpass on the line matching this user.
  awk -v u="$who" -v p="$pw" '
    $0 ~ ("user: " u ",") { sub(/devpass/, p) } { print }
  ' nats/auth.conf > nats/auth.conf.tmp && mv nats/auth.conf.tmp nats/auth.conf
  echo "${who}=${pw}" >> /tmp/team-alpha-passwords.txt
done
docker compose kill -s SIGHUP nats || docker compose restart nats
echo "→ passwords rotated. /tmp/team-alpha-passwords.txt (chmod 600). Verify nats:"
nats --server nats://localhost:4222 --user sysadmin \
     --password "$(grep ^sysadmin= /tmp/team-alpha-passwords.txt | cut -d= -f2)" \
     --timeout 3s pub _probe '{}' && echo OK
```

If the verify fails, stop. Don't proceed to Step 2.

## Step 2 — per-colleague loop

For each colleague Mihai introduces, run this loop. Don't
parallelize — one at a time, each with Mihai's review.

### 2a. Ask the questionnaire

Ask all of these in ONE message, numbered, then wait:

1. **Real name** (used in role brief, not as NATS user)
2. **Slack / preferred handle** (for the brief's "how to reach me" section)
3. **Assigned role** — pick one of `{priya, raj, lin, sam, diego}` based on
   their primary skill. (You may suggest based on the next answers.)
4. **Obsidian 1-1 note path** (relative to `~/exasol`) — the file
   with prior 1-1 notes Mihai keeps for this person. May not
   exist; that's fine.
5. **Jira project key** (e.g. `SPOT`, `EXP`) — what project they
   work in. Optional secondary: their Atlassian account ID for
   exact ticket lookup.
6. **Recent Jira focus** — JQL hint or "last sprint" or "last 6
   months" — anything that narrows the ticket search.
7. **Comm style hints from Mihai** (one or two adjectives —
   "direct, brief", "patient teacher", "cautious", "pushy").

### 2b. Pull signals (in parallel)

Spawn TWO agents in the same message:

- **obsidian-vault-explorer** — read the 1-1 note path + search
  vault for additional mentions of this person. Return a 200-300
  word brief of: their focus areas, ongoing concerns, projects,
  any "they prefer X" notes, friction points with the team.
- **general-purpose** — use plugin_atlassian to fetch the 5-10
  most recent Jira issues this person has worked on (assigned,
  reporter, or recent comments). Return a brief summary: what
  domains they touched, ticket sizes, whether they lead or
  follow, any patterns (always closes infra tickets, always
  punts UI work, etc).

While those run, you can ask Mihai any clarifying questions.

### 2c. Synthesize persona draft

When both agents return, write a draft persona block in this
shape and show Mihai for review:

```markdown
# <role>.md additions for <real-name>

## Who you are

You are <real-name>. <one-sentence identity>. <one-sentence
work style>.

## Skills (where you lead, where you grow)

- Primary:  <2-3 skills from Jira+Obsidian signal>
- Growing:  <1-2 stretch skills>
- Avoid:    <skills they explicitly punt on, if any>

## Communication style

<derived from Mihai's hints + 1-1 vibes — 2-3 sentences>

## Ongoing context

<2-3 bullet points about active concerns / projects from
the signals — gives the agent some recent-history flavor>

## How to reach me out-of-band

Slack: @<handle>. <when responsive>.
```

Ask Mihai: "Approve this persona, or want changes?" Iterate
until approval.

### 2d. Apply on approval

When Mihai says approve:

1. Read the existing `scripts/agent-prompts/<role>.md` end-to-end
   so you keep the parts that are role-functional (Runtime task
   board section, A2A dispatch section, Cycle loop, etc).
2. **Replace** any existing "## Who you are" / "## Skills" /
   "## Communication style" / "## Ongoing context" / "## How to
   reach me" sections with the approved draft. **Insert** them
   near the top (after the role-overview block and before
   "## Runtime task board") if the role brief doesn't have them
   yet.
3. Read `agents/<role>.json`. Update the `description` field +
   `skills[]` array if the persona's skill list differs from
   what's on disk. Keep the JSON shape identical otherwise.
4. Re-read `scripts/agent-prompts/<role>.md` once after the edit
   to confirm nothing got mangled.
5. Print the **distribution block** for this colleague:

```text
=== Distribution block for <real-name> (role: <role>) ===

Send to <real-name> via 1Password / Bitwarden Send (NEVER plain chat):

  NATS URL:  wss://nats.<your-domain>
  Role:      <role>
  Password:  <look up <role>= line in /tmp/team-alpha-passwords.txt>

Repo URL: <ai-over-nats clone URL>

Setup commands they run on their machine:

  git clone <repo-url> ~/Repos/ai-over-nats
  bash ~/Repos/ai-over-nats/scripts/join.sh <role> <their-work-repo>

(They paste the password when join.sh prompts.)
=== end ===
```

### 2e. Move on to next colleague

Confirm with Mihai before starting the next one. He may want
a coffee break.

## Step 3 — final summary

When all colleagues are done:

1. Print a table:

```
| Real name | Role  | Repo focus     | Status      |
|-----------|-------|----------------|-------------|
| Alice     | priya | terraform      | configured  |
| Bob       | raj   | python lib     | configured  |
| ...       | ...   | ...            | ...         |
```

2. Diff `scripts/agent-prompts/{priya,raj,lin,sam,diego}.md` and
   `agents/*.json` so Mihai can review the cumulative changes.
3. Ask: "Commit these now (`Card 221: configure roles for live
   session`) or hold for review?"
4. On approval, commit.

## Hard rules

- **Never** write a real password to disk outside
  `nats/auth.conf` and `/tmp/team-alpha-passwords.txt`.
- **Never** print real passwords in chat — point to the line in
  `/tmp/team-alpha-passwords.txt` instead.
- **Never** push the auth.conf to git (it's gitignored — verify
  with `git status nats/auth.conf` before any commit).
- **Always** show the persona draft to Mihai before applying.
  This is judgment work; don't auto-apply.
- **Always** preserve the role-functional sections in
  `<role>.md` — only replace the persona-shaped sections.
- **One colleague at a time.** Don't queue up Q's for everyone
  upfront — the one-1-1 + Jira fetch is per-person work.

## If something goes wrong

- nats reload didn't take: `docker compose restart nats` and
  re-verify with the sysadmin probe in Step 1.
- Obsidian agent finds nothing: ask Mihai to dump 2-3 paragraphs
  about the person from memory; treat it as the signal.
- Jira agent finds nothing: ask Mihai for a manual list of
  ticket areas / projects; treat as signal.
- A persona draft feels generic: tell Mihai it feels generic;
  ask for one anecdote that captures their working style. Use
  it.

That's the runbook. Begin with the pre-flight checks and report
back.
