#!/usr/bin/env python3
"""Generate agents/<role>.json from acl.py — single source of truth.

Slice 1 (team-alpha-a2a-impl-slice1.md). Skills from TASK_DOMAINS
(tier=primary), LEARNING_CLAIM_DOMAINS minus TASK_DOMAINS (tier=growing).
Mentoring flagged from MENTOR_DOMAINS. Auth scheme nats-user.

CI usage: re-run, then `git diff --exit-code agents/`.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC = REPO_ROOT / "mcp-server" / "src"
sys.path.insert(0, str(SRC))

from team_alpha_mcp import acl  # noqa: E402

ROLES = ["maya", "raj", "lin", "sam", "diego", "priya"]

DESCRIPTIONS = {
    "maya":  "Manager — coordinates, reviews, unblocks; some Python/AWS background.",
    "raj":   "Senior generalist — Terraform/AWS/Python/Go; mentors any domain.",
    "lin":   "Mid generalist — Python+UI, growing into Go.",
    "sam":   "UI specialist — React/design systems, growing into backend.",
    "diego": "Go/backend specialist, growing into infra.",
    "priya": "Terraform/AWS specialist, growing into Python.",
}


def card_for(role: str) -> dict:
    primary = sorted(acl.TASK_DOMAINS.get(role, set()))
    learning = acl.LEARNING_CLAIM_DOMAINS.get(role, set())
    growing = sorted(learning - acl.TASK_DOMAINS.get(role, set()))
    mentors = acl.MENTOR_DOMAINS.get(role, set())

    skills: list[dict] = []
    for sid in primary:
        entry = {"id": sid, "tier": "primary"}
        if sid in mentors:
            entry["mentor"] = True
        skills.append(entry)
    for sid in growing:
        skills.append({"id": sid, "tier": "growing"})

    role_kind = "manager" if role in acl.MANAGER else "worker"

    return {
        "name": role,
        "version": "1.0",
        "role": role_kind,
        "description": DESCRIPTIONS[role],
        "skills": skills,
        "auth": {"scheme": "nats-user", "user": role},
        "endpoints": {
            "tasks_send":  f"nats:// a2a.{role}.tasks.send",
            "task_status": f"nats:// a2a.{role}.tasks.*.status",
            "discovery":   f"nats:// a2a.discovery.{role}",
        },
        "lifecycle_states": [
            "submitted", "working", "input-required",
            "completed", "failed", "canceled",
        ],
    }


def main() -> int:
    out_dir = REPO_ROOT / "agents"
    out_dir.mkdir(exist_ok=True)
    changed: list[str] = []
    for role in ROLES:
        card = card_for(role)
        body = json.dumps(card, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        path = out_dir / f"{role}.json"
        prev = path.read_text() if path.exists() else None
        if prev != body:
            path.write_text(body)
            changed.append(role)
    if changed:
        print(f"wrote {len(changed)} card(s): {', '.join(changed)}")
    else:
        print("no changes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
