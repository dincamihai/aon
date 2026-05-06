"""MAP-Elites archive for cmd-gate classifier prompts.

Stores prompts in cells defined by behaviour bands:
  (fpr_band, fnr_band, latency_band)

Each cell holds exactly one champion: the highest-fitness prompt
that lands in that cell. Improvements within a cell replace the
champion; new cells expand coverage.

Layout on disk (under $AON_GATE_EVOLVE_DIR/archive/):
  cells/<fpr>-<fnr>-<lat>/champion.txt   prompt text
                          /scores.json    full score vector
                          /history.jsonl  every prompt ever in this cell
  index.jsonl                              one line per cell
  champions.log                            deploy history
"""
from __future__ import annotations

import hashlib
import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterator, Optional


# Behaviour-band thresholds. Conservative defaults; tune once the
# archive accumulates real data.
FPR_BANDS = [0.0, 0.01, 0.05, 0.20, 1.01]   # low / med / high / xhigh
FNR_BANDS = [0.0, 0.05, 0.15, 0.40, 1.01]
LAT_BANDS = [0, 1500, 3000, 6000, 10**6]    # ms

POSTURES = {
    # cell preference order per posture
    "tight":    lambda fpr, fnr, lat: (fpr, fnr, lat),       # min FPR first
    "balanced": lambda fpr, fnr, lat: (fpr + fnr, lat, fpr),  # min sum
    "fast":     lambda fpr, fnr, lat: (lat, fpr + fnr, fpr),  # min latency
}


@dataclass
class Scores:
    fpr: float
    fnr: float
    p50_latency_ms: int
    accuracy: float
    pairs_evaluated: int

    def cell(self) -> tuple[int, int, int]:
        return (
            _band(self.fpr, FPR_BANDS),
            _band(self.fnr, FNR_BANDS),
            _band(self.p50_latency_ms, LAT_BANDS),
        )

    def fitness(self) -> float:
        # Higher is better. Symmetric on FPR/FNR; mild latency penalty.
        return self.accuracy - 0.5 * max(0.0, self.p50_latency_ms - 3000) / 10000


def _band(v: float, bands: list[float]) -> int:
    for i, edge in enumerate(bands[1:]):
        if v < edge:
            return i
    return len(bands) - 2


class Archive:
    def __init__(self, root: Optional[Path] = None) -> None:
        base = root or Path(
            os.environ.get(
                "AON_GATE_EVOLVE_DIR",
                str(Path.home() / ".aon" / "security" / "evolve"),
            )
        )
        self.root = base / "archive"
        self.cells = self.root / "cells"
        self.index = self.root / "index.jsonl"
        self.champions_log = self.root / "champions.log"
        self.cells.mkdir(parents=True, exist_ok=True)

    def add(self, prompt: str, scores: Scores) -> tuple[bool, str]:
        """Add a prompt. Returns (replaced_champion, cell_id)."""
        cell = scores.cell()
        cell_id = "-".join(map(str, cell))
        cell_dir = self.cells / cell_id
        cell_dir.mkdir(parents=True, exist_ok=True)
        history = cell_dir / "history.jsonl"
        champion = cell_dir / "champion.txt"
        scores_path = cell_dir / "scores.json"

        prompt_hash = hashlib.sha256(prompt.encode()).hexdigest()[:12]
        record = {
            "ts": _now(),
            "hash": prompt_hash,
            "scores": asdict(scores),
            "fitness": scores.fitness(),
        }
        with history.open("a") as f:
            f.write(json.dumps(record) + "\n")

        replaced = False
        if scores_path.exists():
            prev = json.loads(scores_path.read_text())
            if scores.fitness() <= prev["fitness"]:
                self._rewrite_index()
                return False, cell_id
            replaced = True

        champion.write_text(prompt)
        scores_path.write_text(json.dumps(record))
        self._rewrite_index()
        return replaced, cell_id

    def _rewrite_index(self) -> None:
        rows = []
        for cd in sorted(self.cells.glob("*")):
            sp = cd / "scores.json"
            if sp.exists():
                rec = json.loads(sp.read_text())
                rows.append({"cell": cd.name, **rec})
        self.index.write_text("\n".join(json.dumps(r) for r in rows) + "\n" if rows else "")

    def front(self) -> list[dict]:
        if not self.index.exists():
            return []
        return [json.loads(line) for line in self.index.read_text().splitlines() if line.strip()]

    def champion(self, posture: str = "balanced") -> Optional[tuple[str, dict]]:
        rows = self.front()
        if not rows:
            return None
        if posture not in POSTURES:
            raise ValueError(f"unknown posture: {posture}")
        keyfn = POSTURES[posture]
        rows_sorted = sorted(
            rows,
            key=lambda r: keyfn(
                r["scores"]["fpr"],
                r["scores"]["fnr"],
                r["scores"]["p50_latency_ms"],
            ),
        )
        best = rows_sorted[0]
        prompt_path = self.cells / best["cell"] / "champion.txt"
        return prompt_path.read_text(), best

    def history(self, n: int = 50) -> list[dict]:
        if not self.champions_log.exists():
            return []
        lines = self.champions_log.read_text().splitlines()[-n:]
        return [json.loads(l) for l in lines if l.strip()]

    def record_deploy(self, cell_id: str, prompt_hash: str, posture: str) -> None:
        rec = {"ts": _now(), "cell": cell_id, "hash": prompt_hash, "posture": posture}
        with self.champions_log.open("a") as f:
            f.write(json.dumps(rec) + "\n")

    def iter_champions(self) -> Iterator[tuple[str, str, dict]]:
        """Yield (cell_id, prompt, scores) for every populated cell."""
        for cd in sorted(self.cells.glob("*")):
            sp = cd / "scores.json"
            cp = cd / "champion.txt"
            if sp.exists() and cp.exists():
                yield cd.name, cp.read_text(), json.loads(sp.read_text())


def _now() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _cli() -> None:
    """CLI: archive list | show <cell> | front [posture]"""
    import sys
    a = Archive()
    args = sys.argv[1:]
    if not args:
        args = ["list"]
    cmd, *rest = args
    if cmd == "list":
        for cell, prompt, scores in a.iter_champions():
            print(f"{cell}\tfitness={scores['fitness']:.4f}\t"
                  f"acc={scores['scores']['accuracy']:.3f}\t"
                  f"fpr={scores['scores']['fpr']:.3f}\t"
                  f"fnr={scores['scores']['fnr']:.3f}\t"
                  f"p50={scores['scores']['p50_latency_ms']}ms\t"
                  f"hash={scores['hash']}")
    elif cmd == "show":
        cell = rest[0]
        cd = a.cells / cell
        if not (cd / "champion.txt").exists():
            sys.exit(f"no such cell: {cell}")
        print(cd.joinpath("champion.txt").read_text())
    elif cmd == "front":
        posture = rest[0] if rest else "balanced"
        result = a.champion(posture)
        if not result:
            sys.exit("archive empty")
        prompt, scores = result
        print(f"# posture={posture} cell={scores['cell']} fitness={scores['fitness']:.4f}")
        print(prompt)
    else:
        sys.exit(f"usage: archive.py [list|show <cell>|front [posture]]")


if __name__ == "__main__":
    _cli()
