"""Entry point for the `aon` console script.

Resolution order for the engine root (where bin/aon lives):

1. `$AON_ENGINE_DIR` env override.
2. Walk up from this file until we find a sibling `bin/aon`. This works
   when the package is installed editable (`pipx install -e .` or
   `pip install -e .`) — the package directory is inside the engine
   source tree, so `bin/aon` is a sibling-of-parent.
3. Fail with a clear hint to either set `AON_ENGINE_DIR` or do an
   editable install.

The wrapper uses `os.execvp` (not subprocess) so signals + stdio +
the exit code pass through cleanly to the bash CLI.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _find_engine_dir() -> Path:
    env = os.environ.get("AON_ENGINE_DIR")
    if env:
        candidate = Path(env)
        if (candidate / "bin" / "aon").is_file():
            return candidate
        sys.stderr.write(
            f"aon: AON_ENGINE_DIR={env} does not contain bin/aon\n"
        )
        sys.exit(2)

    # Walk up from this file. For editable installs, parent of the
    # package directory is the engine root.
    here = Path(__file__).resolve()
    for parent in [here.parent, *here.parents]:
        if (parent / "bin" / "aon").is_file():
            return parent

    sys.stderr.write(
        "aon: cannot locate engine root.\n"
        "Either:\n"
        "  - set AON_ENGINE_DIR to your ai-over-nats checkout, or\n"
        "  - install editable:  pipx install --editable <path-to-ai-over-nats>\n"
    )
    sys.exit(2)


def main() -> None:
    engine = _find_engine_dir()
    bash_cli = engine / "bin" / "aon"
    # exec replaces this process; signals + stdio passthrough.
    os.execvp("bash", ["bash", str(bash_cli), *sys.argv[1:]])
