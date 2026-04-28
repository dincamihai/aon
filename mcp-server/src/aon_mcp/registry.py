"""cwd → ~/.aon/ registry resolver.

Reads ~/.aon/work-repos.json and resolves the current process's cwd
(or any ancestor up to fs root) to a (team, role, nats_url, creds_path,
kv_bucket) tuple. Returns None when no entry matches; caller falls back
to env vars for back-compat with stamped repos.

The MCP server inherits claude's cwd at startup, so resolving from cwd
gives the right team without baked .mcp.json env vars.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Resolved:
    team: str
    role: str
    nats_url: str
    creds_path: str
    kv_bucket: str


def _registry_path() -> Path:
    return Path(os.path.expanduser("~/.aon/work-repos.json"))


def _team_creds_dir(team: str) -> Path:
    return Path(os.path.expanduser(f"~/.aon/teams/{team}/creds"))


def _read_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def resolve_from_cwd(start: Path | None = None) -> Resolved | None:
    """Walk from cwd up to filesystem root, return first registry hit."""
    reg = _registry_path()
    if not reg.is_file():
        return None
    try:
        entries = json.loads(reg.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(entries, list):
        return None

    cwd = (start or Path.cwd()).resolve()
    candidates = [cwd, *cwd.parents]

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        try:
            entry_path = Path(entry["path"]).resolve()
            team = entry["team"]
            role = entry["role"]
        except (KeyError, OSError):
            continue
        if entry_path not in candidates:
            continue

        creds_dir = _team_creds_dir(team)
        creds_path = creds_dir / f"{role}.password"
        if not creds_path.is_file():
            return None

        env = _read_env_file(creds_dir / f"{role}.env")
        nats_url = env.get("AON_NATS_URL", "")
        kv_bucket = env.get("AON_KV_BUCKET", "team-state")
        return Resolved(
            team=team,
            role=role,
            nats_url=nats_url,
            creds_path=str(creds_path),
            kv_bucket=kv_bucket,
        )
    return None
