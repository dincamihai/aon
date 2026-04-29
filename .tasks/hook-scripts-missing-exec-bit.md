---
column: Done
priority: medium
created: 2026-04-29
fixed-in: sun/fix-trivials-2026-04-29 @ 508e081
source: sun while wiring `aon join` for workers repo
---

# Hook scripts committed without execute bit — `aon hook` launcher rejects them

`aon hook <name>` (bin/aon:2588) tests `[[ ! -x "$hook_path" ]]` and exits with `no hook script: <path>` if the bit is unset. 8 of 12 scripts in `scripts/hooks/` shipped 0644:

- stop.sh
- post-tool-use.sh
- pre-compact.sh
- session-start-catch-up.sh
- session-start-onboard.sh
- session-end-goodbye.sh
- user-prompt-submit.sh
- _lib.sh (sourced — needs +x for consistency with the rest)

Symptom: per-repo `.claude/settings.json` Stop / SessionStart / PostToolUse hooks log `no hook script: …/stop.sh` every event. Confusing because `ls` shows the file present — error message names the path but doesn't say the issue is exec bit.

## Fix

`chmod +x scripts/hooks/*.sh` — done in commit 508e081.

## Follow-up (not in this fix)

Improve the error message to call out the exec bit explicitly:

```bash
if [[ ! -x "$hook_path" ]]; then
  if [[ -f "$hook_path" ]]; then
    aon_err "hook script exists but is not executable: $hook_path"
    aon_err "  fix: chmod +x $hook_path"
  else
    aon_err "no hook script: $hook_path"
    aon_err "  fix: ensure 'aon' on PATH points at an engine with scripts/hooks/$name.sh"
  fi
  return 1
fi
```

Plus a CI check / `aon doctor` warning for unbits-set hook files.
