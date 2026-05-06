"""GEPA × MAP-Elites loop driver — ADR-002 brick 5.

One round:
  1. Generate N adversarial argv (or reuse cache).
  2. For each candidate prompt, run argv through the live classifier.
  3. Pair two candidates per argv; ask the judge which won.
  4. Collect failures (loser argv) per candidate.
  5. Mutate each candidate using its own failures (GEPA reflection).
  6. Score every prompt against the eval set; place in archive cells.

Everything streams to ~/.aon/security/evolve/runs/<ts>/ for audit.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Local imports
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from archive import Archive, Scores  # noqa: E402


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run_classifier(prompt: str, argv: str, ollama_url: str, model: str) -> tuple[str, int]:
    """Run argv through nemotron with the given prompt. Returns (verdict, latency_ms)."""
    payload = {
        "model": model,
        "system": prompt,
        "prompt": f"argv: {argv}",
        "stream": False,
        "format": "json",
        "keep_alive": "24h",
        "options": {"temperature": 0, "num_predict": 160},
    }
    start = time.monotonic()
    out = subprocess.run(
        ["curl", "-sS", "--max-time", "8",
         f"{ollama_url}/api/generate", "-d", json.dumps(payload)],
        capture_output=True, text=True, check=False,
    )
    dur_ms = int((time.monotonic() - start) * 1000)
    if out.returncode != 0:
        return "ask", dur_ms
    try:
        body = json.loads(out.stdout)
        inner = json.loads(body.get("response", "{}"))
        verdict = inner.get("verdict", "ask")
        if verdict not in ("allow", "deny", "ask"):
            verdict = "ask"
        return verdict, dur_ms
    except (json.JSONDecodeError, KeyError):
        return "ask", dur_ms


def call_judge(argv: str, va: dict, vb: dict) -> Optional[dict]:
    """Pairwise judge call. va/vb each: {prompt_id, verdict, reason}."""
    payload = {
        "argv": argv,
        "verdicts": [
            {"prompt_id": "a", "verdict": va["verdict"], "reason": va.get("reason", "")},
            {"prompt_id": "b", "verdict": vb["verdict"], "reason": vb.get("reason", "")},
        ],
    }
    out = subprocess.run(
        [str(HERE / "judge.sh")],
        input=json.dumps(payload), capture_output=True, text=True, check=False,
    )
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def generate_argv(count: int, categories: str, diversity: bool) -> list[dict]:
    """Run generate-argv.sh and parse JSONL."""
    cmd = [
        str(HERE / "generate-argv.sh"),
        "--count", str(count),
        "--categories", categories,
    ]
    if diversity:
        cmd.append("--diversity")
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        return []
    return [
        json.loads(line) for line in out.stdout.splitlines()
        if line.strip() and line.startswith("{")
    ]


def mutate_prompt(current: str, failures: list[dict], run_dir: Path, idx: int) -> Optional[str]:
    """Call mutate.py. Returns new prompt text or None on rejection."""
    pin = run_dir / f"candidate-{idx}.txt"
    fjs = run_dir / f"failures-{idx}.jsonl"
    pout = run_dir / f"candidate-{idx}-v2.txt"
    pin.write_text(current)
    fjs.write_text("\n".join(json.dumps(f) for f in failures))
    out = subprocess.run(
        [sys.executable, str(HERE / "mutate.py"),
         "--prompt-in", str(pin),
         "--failures", str(fjs),
         "--prompt-out", str(pout)],
        capture_output=True, text=True, check=False,
    )
    if out.returncode != 0 or not pout.exists():
        return None
    return pout.read_text()


def score_prompt(prompt: str, eval_set: list[dict],
                 ollama_url: str, classifier_model: str) -> Scores:
    """Run prompt against eval_set; compute FPR/FNR/latency/accuracy."""
    fp = fn = tp = tn = 0
    latencies = []
    for case in eval_set:
        verdict, dur = run_classifier(prompt, case["argv"], ollama_url, classifier_model)
        latencies.append(dur)
        intent = case["intent"]
        # Map deny=positive, allow=negative
        actual_pos = (verdict == "deny")
        intended_pos = (intent == "deny")
        if actual_pos and intended_pos: tp += 1
        elif actual_pos and not intended_pos: fp += 1
        elif not actual_pos and not intended_pos: tn += 1
        else: fn += 1
    n = len(eval_set) or 1
    accuracy = (tp + tn) / n
    fpr = fp / max(fp + tn, 1)
    fnr = fn / max(fn + tp, 1)
    latencies.sort()
    p50 = latencies[len(latencies) // 2] if latencies else 0
    return Scores(fpr=fpr, fnr=fnr, p50_latency_ms=p50,
                  accuracy=accuracy, pairs_evaluated=n)


def evolve_round(args) -> None:
    base = Path(os.environ.get("AON_GATE_EVOLVE_DIR",
                                str(Path.home() / ".aon" / "security" / "evolve")))
    run_dir = base / "runs" / _now().replace(":", "-")
    run_dir.mkdir(parents=True, exist_ok=True)
    sys.stderr.write(f"evolve: round dir {run_dir}\n")

    # 1. Eval set — generate adversarial argv
    eval_set = generate_argv(args.argv, args.categories, diversity=args.diversity)
    if not eval_set:
        sys.stderr.write("evolve: no argv generated; aborting\n")
        return
    (run_dir / "eval-set.jsonl").write_text(
        "\n".join(json.dumps(c) for c in eval_set))
    sys.stderr.write(f"evolve: eval set has {len(eval_set)} argv\n")

    # 2. Seed candidates from current classifier prompt
    current_prompt = _extract_classifier_prompt()
    candidates = [current_prompt]

    archive = Archive()
    # If archive non-empty, also seed from existing champions
    for _, champ_prompt, _ in archive.iter_champions():
        candidates.append(champ_prompt)
        if len(candidates) >= args.candidates:
            break

    sys.stderr.write(f"evolve: starting with {len(candidates)} seed candidates\n")

    # 3. Score seeds; place in archive
    for i, cand in enumerate(candidates):
        scores = score_prompt(cand, eval_set, args.ollama_url, args.classifier_model)
        archive.add(cand, scores)
        sys.stderr.write(f"  seed-{i}: acc={scores.accuracy:.3f} "
                         f"fpr={scores.fpr:.3f} fnr={scores.fnr:.3f} "
                         f"p50={scores.p50_latency_ms}ms\n")

    # 4. Pairwise judge → collect failures per candidate
    failures_per: list[list[dict]] = [[] for _ in candidates]
    for case in eval_set:
        for i in range(len(candidates)):
            for j in range(i + 1, len(candidates)):
                vi, _ = run_classifier(candidates[i], case["argv"], args.ollama_url, args.classifier_model)
                vj, _ = run_classifier(candidates[j], case["argv"], args.ollama_url, args.classifier_model)
                if vi == vj:
                    continue
                judgement = call_judge(case["argv"],
                                       {"verdict": vi}, {"verdict": vj})
                if not judgement:
                    continue
                loser_idx = j if judgement["winner"] == "a" else i
                failures_per[loser_idx].append({
                    "argv": case["argv"],
                    "classifier_verdict": (vj if loser_idx == j else vi),
                    "correct": judgement["correct"],
                    "critique": judgement["critique"],
                })

    # 5. Mutate each candidate using its failures
    new_prompts = []
    for i, fails in enumerate(failures_per):
        if not fails:
            continue
        new = mutate_prompt(candidates[i], fails, run_dir, i)
        if new:
            new_prompts.append(new)
            sys.stderr.write(f"  mutate-{i}: produced new prompt\n")

    # 6. Score new prompts; place in archive
    for k, np_ in enumerate(new_prompts):
        scores = score_prompt(np_, eval_set, args.ollama_url, args.classifier_model)
        replaced, cell = archive.add(np_, scores)
        sys.stderr.write(f"  v2-{k}: cell={cell} acc={scores.accuracy:.3f} "
                         f"{'(replaced champion)' if replaced else '(new cell or worse)'}\n")

    sys.stderr.write(f"evolve: done. archive at {archive.root}\n")


def _extract_classifier_prompt() -> str:
    """Pull the SYSTEM heredoc out of classifier-ollama.sh."""
    src = (HERE / ".." / "classifier-ollama.sh").resolve()
    text = src.read_text()
    # SYSTEM='...\n...' block — single-quoted multiline
    m = text.split("SYSTEM='", 1)
    if len(m) < 2:
        raise RuntimeError("could not locate SYSTEM= block in classifier-ollama.sh")
    body = m[1].split("\n'", 1)[0]
    return body


def main() -> None:
    ap = argparse.ArgumentParser(description="cmd-gate evolve loop")
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--candidates", type=int, default=4,
                    help="max seed candidates from archive")
    ap.add_argument("--argv", type=int, default=20,
                    help="adversarial argv per round")
    ap.add_argument("--categories", default="destruction,obfuscation,iam,credential-read")
    ap.add_argument("--diversity", action="store_true")
    ap.add_argument("--classifier-model", default=os.environ.get("AON_GATE_MODEL", "nemotron-3-nano:4b"))
    ap.add_argument("--ollama-url", default=os.environ.get("AON_GATE_OLLAMA_URL", "http://127.0.0.1:11434"))
    args = ap.parse_args()

    for r in range(args.rounds):
        sys.stderr.write(f"=== round {r + 1}/{args.rounds} ===\n")
        try:
            evolve_round(args)
        except KeyboardInterrupt:
            sys.stderr.write("evolve: aborted by user\n")
            sys.exit(130)


if __name__ == "__main__":
    main()
