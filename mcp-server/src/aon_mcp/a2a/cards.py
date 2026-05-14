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


def _agents_dir() -> Path | None:
    """Resolve agents/ dir. Returns None if not found — a2a discovery
    then degrades to a no-op rather than crashing module import."""
    override = os.environ.get("AON_AGENTS_DIR")
    if override:
        p = Path(override).expanduser().resolve()
        return p if p.is_dir() else None
    # Walk up from this file: mcp-server/src/aon_mcp/a2a/cards.py
    # → repo_root/agents
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "agents"
        if candidate.is_dir():
            return candidate
    # $PWD fallback (MCP server typically launches in a team work-tree).
    cwd_candidate = Path.cwd() / "agents"
    if cwd_candidate.is_dir():
        return cwd_candidate
    return None


def _discover_roles() -> tuple[str, ...]:
    """Discover roles from agent card files. Empty tuple if dir missing
    or empty — keeps the MCP server bootable without a2a cards present."""
    agents_dir = _agents_dir()
    if agents_dir is None:
        return ()
    roles = []
    for f in agents_dir.glob("*.json"):
        name = f.stem
        if name:
            roles.append(name)
    return tuple(sorted(roles))


ALL_ROLES: tuple[str, ...] = _discover_roles()


_CACHE: dict[str, tuple[float, dict]] = {}


def load_card(role: str) -> dict[str, Any]:
    """Load `agents/<role>.json`. Cache invalidated on file mtime change."""
    base = _agents_dir()
    if base is None:
        raise FileNotFoundError(
            "agents/ directory not found; set AON_AGENTS_DIR"
        )
    path = base / f"{role}.json"
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
            if tier is not None and tier not in s.get("tags", []):
                continue
            out.append(role)
            break
    return sorted(out)


def card_skill_tier(role: str, skill: str) -> str | None:
    """Return the tier this role advertises for `skill`, or None."""
    for s in load_card(role).get("skills", []):
        if s.get("id") == skill:
            tags = s.get("tags", [])
            return tags[0] if tags else None
    return None


def verify_card_acl_scope(role: str, entry_key: str) -> bool:
    """Return True if KV entry key matches the expected ACL-scoped pattern.

    Trust model: NATS ACL restricts writes to $KV.<bucket>.agents.<role>.card
    to the role's own creds. A mismatch means the entry was written via a
    different key path — not necessarily a forgery, but worth logging.
    NATS KV entry.key is the bare key within the bucket (no bucket prefix).
    """
    return entry_key == f"agents.{role}.card"
