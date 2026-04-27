"""Agent card loader — git-file source of truth (drift resolution #1, slice 1 #c).

Reads `agents/<role>.json` from repo root. In-memory cache; reload on mtime
change. NATS-based discovery (`a2a.discovery.<role>`) deferred to slice 2.
"""
from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

ALL_ROLES: tuple[str, ...] = ("maya", "raj", "lin", "sam", "diego", "priya", "mihai")


def _agents_dir() -> Path:
    override = os.environ.get("TEAM_ALPHA_AGENTS_DIR")
    if override:
        return Path(override).expanduser().resolve()
    # Walk up from this file: mcp-server/src/team_alpha_mcp/a2a/cards.py
    # → repo_root/agents
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "agents"
        if candidate.is_dir():
            return candidate
    raise FileNotFoundError(
        "agents/ directory not found; set TEAM_ALPHA_AGENTS_DIR"
    )


_CACHE: dict[str, tuple[float, dict]] = {}


def load_card(role: str) -> dict[str, Any]:
    """Load `agents/<role>.json`. Cache invalidated on file mtime change."""
    path = _agents_dir() / f"{role}.json"
    if not path.is_file():
        raise FileNotFoundError(f"agent card missing: {path}")
    mtime = path.stat().st_mtime
    cached = _CACHE.get(role)
    if cached is not None and cached[0] == mtime:
        return cached[1]
    with path.open() as f:
        body = json.load(f)
    _CACHE[role] = (mtime, body)
    return body


def all_cards() -> dict[str, dict]:
    return {role: load_card(role) for role in ALL_ROLES}


def resolve_by_skill(
    skill: str,
    tier: str | None = "primary",
    exclude: set[str] | None = None,
) -> list[str]:
    """Return roles whose card advertises `skill` at `tier` (or any tier
    if tier is None). Sorted alphabetically for determinism.

    `exclude` removes roles from candidate set (e.g. dispatcher self).
    """
    exclude = exclude or set()
    out: list[str] = []
    for role, card in all_cards().items():
        if role in exclude:
            continue
        if card.get("role") != "worker":
            continue
        for s in card.get("skills", []):
            if s.get("id") != skill:
                continue
            if tier is not None and s.get("tier") != tier:
                continue
            out.append(role)
            break
    return sorted(out)


def card_skill_tier(role: str, skill: str) -> str | None:
    """Return the tier this role advertises for `skill`, or None."""
    for s in load_card(role).get("skills", []):
        if s.get("id") == skill:
            return s.get("tier")
    return None
