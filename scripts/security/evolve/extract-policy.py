#!/usr/bin/env python3
"""Extract the SYSTEM= heredoc from classifier-ollama.sh.

Robust against single-quotes inside the body — uses bash's
'\\''-escaping convention. The awk-based extractor was fragile;
this is the canonical reader.

Usage:
  extract-policy.py [<path-to-classifier-ollama.sh>]

Stdout: policy text. Empty on failure.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def extract(path: Path) -> str:
    text = path.read_text()
    # Match SYSTEM='<body>' at top level. Body may contain '\''
    # (escaped single quote in shell). End delimiter: line with single
    # quote followed by newline or EOF.
    m = re.search(r"^SYSTEM='(.*?)\n'\s*$", text, re.DOTALL | re.MULTILINE)
    if not m:
        return ""
    body = m.group(1)
    # Decode bash '\''-escapes back to literal single quotes.
    body = body.replace("'\\''", "'")
    return body


def main() -> int:
    here = Path(__file__).resolve().parent
    default = here / ".." / "classifier-ollama.sh"
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else default.resolve()
    sys.stdout.write(extract(path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
