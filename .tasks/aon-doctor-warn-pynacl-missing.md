---
column: Backlog
priority: low
created: 2026-04-29
parent: aon-connect-pynacl-venv-missing.md
source: joana review of PR #47 — Bug 1 AC 3 not addressed
---

# `aon doctor` should warn when engine venv exists but `pynacl` is missing

PR #47 added auto-bootstrap of `$AON_ENGINE_DIR/.venv` + `pip install pynacl` in `_cmd_connect_python` (Bug 1 AC 1). AC 3 from the parent card is still open: `aon doctor` should surface a warning when the venv exists but `pynacl` is not importable, so operators see the issue before they hit `aon connect`.

## Fix

In `cmd_doctor` (or the engine-deps section of doctor):

```bash
local _venv_py="$AON_ENGINE_DIR/.venv/bin/python3"
if [[ -x "$_venv_py" ]]; then
  if "$_venv_py" -c 'import nacl' >/dev/null 2>&1; then
    aon_ok "engine venv has pynacl"
  else
    aon_warn "engine venv exists at $AON_ENGINE_DIR/.venv but pynacl is missing"
    aon_warn "  fix: $AON_ENGINE_DIR/.venv/bin/pip install pynacl"
    aon_warn "  (or: rm -rf $AON_ENGINE_DIR/.venv and re-run 'aon connect' to auto-bootstrap)"
  fi
fi
```

## Acceptance

1. `aon doctor` on a fresh machine without venv: silent (auto-bootstrap will handle on first connect).
2. `aon doctor` on a machine with venv missing pynacl: warns with the actionable fix.
3. `aon doctor` on a healthy setup: green tick.
