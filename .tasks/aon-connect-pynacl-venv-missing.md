---
column: Backlog
priority: high
created: 2026-04-29
source: rona exploratory (Bug 1) on 4d5911b..62dc26d
---

# `aon connect` hard-fails on fresh env: `ModuleNotFoundError: No module named 'nacl'`

`bin/aon` — `_cmd_connect_python()` prefers `$AON_ENGINE_DIR/.venv/bin/python3`, falls back to system `python3`. Neither path has `pynacl` on a fresh checkout. `aon connect` immediately raises:

```
ModuleNotFoundError: No module named 'nacl'
```

No graceful recovery. No README step instructing the operator how to install.

## Fix

Add a `aon setup` (or document in README) that creates the venv + installs deps:

```sh
python3 -m venv "$AON_ENGINE_DIR/.venv"
"$AON_ENGINE_DIR/.venv/bin/pip" install pynacl
```

Better: have `_cmd_connect_python()` detect missing module and print actionable hint pointing at the setup command.

## Acceptance

1. Fresh clone + `aon connect <team>` either works out of the box or prints a one-line install command.
2. Setup step documented in README "Getting Started".
3. `aon doctor` warns when venv exists but `pynacl` is missing.
