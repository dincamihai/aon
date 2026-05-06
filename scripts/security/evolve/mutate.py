"""GEPA-style reflective prompt mutator.

Reads a current classifier prompt + the failures (argv +
classifier-verdict + judge-correct + critique) and produces a
rewritten prompt that should fix the failures. Backend per
AON_GATE_EVOLVE_BACKEND.

Mutation rules:
- Edits should be minimal; preserve unrelated structure.
- Output ends with a `# rationale: <one line>` comment so reviewers
  see what changed and why.
- Reject mutations that delete more than 30 % of the prompt.
- Reject mutations that remove a documented policy category.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional


HERE = Path(__file__).resolve().parent
LIB = HERE / "_lib.sh"


def call_llm(system: str, user: str) -> str:
    """Shell out to _lib.sh evolve_call_llm. Same backend as judge/generator."""
    cmd = ["bash", "-c", f'. "{LIB}"; evolve_call_llm "$1" "$2"', "_", system, user]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        sys.exit(out.returncode)
    return out.stdout


MUTATOR_SYS = """You are a prompt-tuning expert for a shell-command safety classifier.

You receive:
- The current classifier prompt (system text used by a small local model).
- A list of failures: argv the classifier got wrong, with the judge's
  correct verdict and 1-line critique.

Produce a rewritten classifier prompt that fixes the failures while
preserving the original structure as much as possible.

Rules:
- Make MINIMAL edits. Add or refine policy bullets; don't rewrite from
  scratch.
- Keep the existing schema specification exactly.
- Don't remove categories already in the policy.
- Output ONLY the new prompt text. No JSON wrapper, no markdown fence,
  no commentary.
- End the prompt with exactly one line:
  # rationale: <one short sentence describing the change>"""


def mutate(current: str, failures: list[dict]) -> Optional[str]:
    """Return rewritten prompt, or None if rejected."""
    failures_payload = "\n".join(
        f"- argv: {f['argv']}\n"
        f"  classifier said: {f['classifier_verdict']}\n"
        f"  correct:         {f['correct']}\n"
        f"  critique:        {f['critique']}"
        for f in failures[:20]   # cap at 20 to keep prompt sane
    )
    user = f"""Current classifier prompt:
---
{current}
---

Failures to fix:
{failures_payload}

Rewrite the prompt now. End with `# rationale: ...`."""

    new = call_llm(MUTATOR_SYS, user).strip()

    # Strip stray code fences
    new = re.sub(r"^```[a-z]*\n", "", new)
    new = re.sub(r"\n```$", "", new)
    new = new.strip()

    # Quality gates
    if len(new.splitlines()) < int(0.7 * len(current.splitlines())):
        sys.stderr.write("mutate: rejected (>30% lines deleted)\n")
        return None
    if "# rationale:" not in new.lower():
        sys.stderr.write("mutate: rejected (missing # rationale tag)\n")
        return None

    # Category preservation: every policy category in current must
    # appear in new (case-insensitive substring match).
    for cat in _extract_categories(current):
        if cat.lower() not in new.lower():
            sys.stderr.write(f"mutate: rejected (category '{cat}' missing)\n")
            return None

    return new


def _extract_categories(prompt: str) -> list[str]:
    """Pull category labels out of the policy bullet list. Heuristic."""
    cats = []
    for line in prompt.splitlines():
        m = re.match(r"\s*-\s*(DENY|ALLOW|ASK):\s*", line, re.IGNORECASE)
        if m:
            tail = line[m.end():]
            tail = re.split(r"[,(]", tail)[0].strip()
            if tail:
                cats.append(tail)
    return cats


def _cli() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="GEPA reflective prompt mutator")
    ap.add_argument("--prompt-in", required=True, type=Path)
    ap.add_argument("--failures", required=True, type=Path,
                    help="JSONL: {argv, classifier_verdict, correct, critique}")
    ap.add_argument("--prompt-out", required=True, type=Path)
    args = ap.parse_args()

    current = args.prompt_in.read_text()
    failures = [
        json.loads(line)
        for line in args.failures.read_text().splitlines()
        if line.strip()
    ]
    if not failures:
        sys.stderr.write("no failures to learn from; copying prompt unchanged\n")
        args.prompt_out.write_text(current)
        return

    new = mutate(current, failures)
    if new is None:
        sys.exit(2)
    args.prompt_out.write_text(new + "\n" if not new.endswith("\n") else new)
    sys.stderr.write(
        f"mutate: wrote {args.prompt_out} ({len(new.splitlines())} lines)\n"
    )


if __name__ == "__main__":
    _cli()
