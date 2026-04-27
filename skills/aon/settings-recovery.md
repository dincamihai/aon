---
description: Recover from a joiner's .claude/settings.json containing stale operator-path hook commands (the pre-PR-#26 bug where install.sh's jq merge order leaked the original operator's REPO_ROOT into joiners' work-repo settings). Surgically strips the bad entries while preserving the joiner's other settings (theme, model, permissions, non-team hooks). Use when hook commands point at /Users/<someone-else>/, when SessionStart hooks silently fail on a joiner's box, or when settings.json appears to have hardcoded operator paths. Trigger phrases include "operator path in settings", "settings.json broke", "hook commands point at /Users/mid", "stale hook paths", "hooks pointing to wrong machine".
---

# aon: recover settings.json with stale operator paths

Joiner-side fix. Run when `<work-repo>/.claude/settings.json` (or
`<engine>/.claude/settings.json`) has hook entries pointing at
*another* machine's paths (most commonly `/Users/<operator>/Repos/ai-over-nats/...`),
so SessionStart / Stop / PostToolUse hooks silently fail.

## Inputs

- `<work-repo>` — joiner's work repo directory.
- `<bad-prefix>` — the path prefix that's wrong, e.g.
  `/Users/mid/Repos/ai-over-nats/`. Discover with:

  ```bash
  jq -r '.hooks | .. | objects | select(.command?) | .command' \
    <work-repo>/.claude/settings.json | sort -u
  ```

  Look for entries whose path doesn't match **your** clone of
  ai-over-nats.

## Steps

1. **Pull the engine fix** (if not yet):

   ```bash
   cd ~/Repos/ai-over-nats && git pull
   ```

   PR #26 fixes the root cause (jq merge order + untrack
   settings.json). After this you only need to run the recovery
   below once per stale clone.

2. **Wipe the engine's stale settings.json** (was committed
   pre-PR-#26 with operator paths):

   ```bash
   rm -f ~/Repos/ai-over-nats/.claude/settings.json
   ```

   Next `install.sh install` will recreate from scratch with **your**
   REPO_ROOT.

3. **Surgical strip on work-repo settings.json.** Removes only hook
   entries whose `command` contains the bad prefix. Preserves
   everything else (theme, model, permissions, non-team hooks).

   ```bash
   BAD='<bad-prefix>'   # e.g. /Users/mid/Repos/ai-over-nats/

   jq --arg bad "$BAD" '
     .hooks |= with_entries(
       .value |= map(
         .hooks |= map(select(.command | contains($bad) | not))
       )
     )
   ' <work-repo>/.claude/settings.json > /tmp/s.json && \
     mv /tmp/s.json <work-repo>/.claude/settings.json
   ```

   Verify nothing operator-pathed remains:

   ```bash
   jq -r '.hooks | .. | objects | select(.command?) | .command' \
     <work-repo>/.claude/settings.json | grep -E "^bash $BAD" || echo "clean"
   ```

4. **Re-run `aon join`** to inject correct hooks with **your** path:

   ```bash
   cd ~/Repos/<team>-aon
   aon join <role> <work-repo>
   ```

   `install.sh` (post-PR-#26) writes settings using your local
   REPO_ROOT. The jq env-prefix bake then copies your paths into
   work-repo settings.

5. **Sanity check.** Hook commands should now all reference your
   clone:

   ```bash
   jq -r '.hooks | .. | objects | select(.command?) | .command' \
     <work-repo>/.claude/settings.json | sort -u
   ```

   All should start with `bash <YOUR home>/Repos/ai-over-nats/scripts/hooks/...`.

## When to use full reset instead

If the joiner has no other custom config in `<work-repo>/.claude/settings.json`,
just delete + re-join:

```bash
rm -f <work-repo>/.claude/settings.json
cd ~/Repos/<team>-aon && aon join <role> <work-repo>
```

Faster, but blows away any per-user hooks/settings.

## Why this happened (historical)

`scripts/hooks/install.sh` merged hooks with jq object `+` putting
`(.hooks // {})` on the right side. In jq, right wins on key
collision. Pre-existing entries (from the engine's committed
settings.json with operator paths) won over the freshly-built block
that had the joiner's REPO_ROOT. PR #26 swapped order so freshly-built
wins, and gitignored the committed settings.json so fresh clones
start clean.
