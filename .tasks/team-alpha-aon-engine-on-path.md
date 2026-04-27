---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 249
priority: medium
parent: team-alpha-team-portability
depends_on: team-alpha-meta-engine-vs-team-split
---

> **Status (2026-04-27, slice 7):** ships pyproject.toml +
> `aon_engine/` Python wrapper. `pipx install --editable
> <ai-over-nats-checkout>` produces an `aon` console script on
> PATH that finds the engine via:
>
> 1. `$AON_ENGINE_DIR` env override
> 2. walk-up from `aon_engine/__file__` to find sibling `bin/aon`
>    (works for editable installs)
> 3. error with hint
>
> Wrapper uses `os.execvp("bash", …)` — signals + stdio + exit
> code pass through cleanly.
>
> Smoke: throwaway venv, `pip install -e .`, `aon help` and `aon
> doctor` against `team-poc-aon` both produce expected output.
>
> README operator quickstart + joiner quickstart updated to
> show pipx editable as the recommended path; ln -s symlink
> kept as Option B.
>
> True zero-clone (bundle bash via package_data) deferred —
> requires moving bin/templates/scripts into the package
> directory or adding a build step. Editable install gets us
> 95% of the value with zero churn.

# Card 249 — Engine on PATH (`pipx install` / `brew tap`)

Today every operator + joiner runs aon via the absolute path
`~/Repos/ai-over-nats/bin/aon` or `ln -s` into `~/.local/bin/`.
Mentioned in README §1.1 — manual.

## Goal

Engine ships as an installable, system-wide binary:

- **`pipx install`** preferred (Python-tooling-aligned with
  mcp-server already in the repo). Add a thin Python wrapper
  that execs the bash CLI; pyproject.toml entry-point.
- **`brew tap dincamihai/aon`** alternative for macOS users
  who don't use pipx.

Either way, `aon help` works without knowing where the engine
lives on disk; the binary discovers `AON_ENGINE_DIR` from its
own install path.

## Deliverables

- `pyproject.toml` adds `aon` console-script (calls
  `aon/wrapper.py` → `os.execvp("bash", [bin/aon, …sys.argv])`).
- Bash CLI updated to read `AON_ENGINE_DIR` from
  `os.path.dirname(__file__)/..` resolution that survives the
  pipx wrapper.
- README §1.1 simplified: `pipx install ai-over-nats` (one
  line, no symlink dance).
- (Optional) `Formula/aon.rb` for `brew tap`.

## Acceptance

- Fresh box: `pipx install ai-over-nats` → `aon help` works
  without symlinking, without cloning.
- `aon` on PATH from a totally different cwd; subcommands
  resolve templates relative to the installed engine root.

## Why

Removes the last "you have to clone the engine first" step
for joiners (Card 247) and operators alike. Engine becomes a
real distributable.

## Risk

Some templates use bash features (heredocs, nested awk).
Wrapper must preserve quoting + arg semantics. Use
`os.execvp` not `subprocess.run` to avoid shell parsing.
