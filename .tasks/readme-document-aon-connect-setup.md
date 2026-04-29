---
column: Done
priority: low
created: 2026-04-29
parent: aon-connect-pynacl-venv-missing.md
source: joana review of PR #47 — Bug 1 AC 2 not addressed
---

# Document `aon connect` setup in README (Getting Started)

PR #47 added auto-bootstrap so a fresh machine can run `aon connect` without pre-installing pynacl. AC 2 from the parent card is still open: README should document the joiner setup path so operators know what's happening when the auto-install runs (and what to do if it fails behind a firewall / no pip access).

## Fix

Add a "Joining a team" section to `README.md` (or extend an existing one) covering:

1. Prerequisites: `python3` with `venv` module, network access to PyPI on first run.
2. What auto-bootstrap does on first `aon connect`: creates `$AON_ENGINE_DIR/.venv`, installs `pynacl`. One-time.
3. Manual install path for air-gapped / restricted networks:
   ```sh
   python3 -m venv "$AON_ENGINE_DIR/.venv"
   "$AON_ENGINE_DIR/.venv/bin/pip" install pynacl
   ```
4. Verifying with `aon doctor` (depends on `aon-doctor-warn-pynacl-missing.md` landing first; cross-link).

## Acceptance

1. README has a discoverable "Joining a team" or "Getting Started" section that names the auto-bootstrap behavior.
2. Manual fallback documented for offline environments.
3. Cross-reference to `aon doctor` once the warn-on-missing feature ships.
