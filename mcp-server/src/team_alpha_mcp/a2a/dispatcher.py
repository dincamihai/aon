"""A2A dispatcher — directed-dispatch by skill match.

Pick rule (drift resolution #5):
    1. continuity bias on parent_task_id (AUDIT lookup → last completer)
    2. project_id bias (KV `project.<pid>.last_worker`)
    3. load-aware fallback (KV `agent.<role>.load.current_tasks`)

Returns (target_role, reply_dict) on success, or raises DispatchError.
"""
from __future__ import annotations

import logging
import secrets
from typing import Any

from .. import crypto
from .cards import resolve_by_skill, ALL_ROLES
from .schemas import validate_task_send

log = logging.getLogger(__name__)


class DispatchError(RuntimeError):
    pass


def new_task_id() -> str:
    return f"t-{secrets.token_hex(6)}"


async def _continuity_pick(
    client, parent_task_id: str, candidates: list[str]
) -> str | None:
    if not parent_task_id:
        return None
    events = await client.recent_events(
        subject=f"a2a.*.tasks.{parent_task_id}.status",
        since="30d",
        limit=50,
    )
    for ev in events:
        try:
            inner = crypto.unwrap_dict(ev)
        except crypto.CryptoError as e:
            log.warning("continuity: skipping unverifiable event: %s", e)
            continue
        if inner.get("state") == "completed":
            by = inner.get("by")
            if by in candidates:
                return by
    return None


async def _project_pick(
    client, project_id: str, candidates: list[str]
) -> str | None:
    if not project_id:
        return None
    val = await client.kv_get(f"project.{project_id}.last_worker")
    if not isinstance(val, dict):
        return None
    role = val.get("role")
    return role if role in candidates else None


async def _load_pick(client, candidates: list[str]) -> str:
    """Pick lowest-load candidate. Missing KV → 0 (idle). Tiebreak alpha."""
    best: tuple[int, str] | None = None
    for role in candidates:
        load = await client.kv_get(f"agent.{role}.load")
        n = 0
        if isinstance(load, dict):
            try:
                n = int(load.get("current_tasks", 0))
            except (TypeError, ValueError):
                n = 0
        key = (n, role)
        if best is None or key < best:
            best = key
    assert best is not None
    return best[1]


async def _pick_target(
    client,
    skill: str,
    parent_task_id: str | None,
    project_id: str | None,
    exclude_self: str | None,
) -> str:
    exclude = {exclude_self} if exclude_self else set()
    candidates = resolve_by_skill(skill, tier="primary", exclude=exclude)
    if not candidates:
        # fall back to any tier
        candidates = resolve_by_skill(skill, tier=None, exclude=exclude)
    if not candidates:
        raise DispatchError(f"no agent advertises skill={skill!r}")

    if parent_task_id:
        pick = await _continuity_pick(client, parent_task_id, candidates)
        if pick:
            return pick
    if project_id:
        pick = await _project_pick(client, project_id, candidates)
        if pick:
            return pick
    return await _load_pick(client, candidates)


async def dispatch_task(
    client,
    skill: str,
    payload: dict[str, Any],
    parent_task_id: str | None = None,
    project_id: str | None = None,
    priority: str = "medium",
    timeout: float = 5.0,
) -> dict[str, Any]:
    """Pick target by skill match + continuity/load, send request, return:

        {"task_id": ..., "target_role": ..., "ack": <reply or None>}

    `client` is a TeamAlphaClient (Maya's). Worker on the receiving side
    sends ack via NATS reply (e.g. `{"ok": true, "task_id": ...}`).
    """
    target = await _pick_target(
        client, skill, parent_task_id, project_id, exclude_self=client.role
    )
    task_id = new_task_id()

    body: dict[str, Any] = {
        "task_id": task_id,
        "skill": skill,
        "payload": payload,
        "priority": priority,
        "from": client.role,
    }
    if parent_task_id:
        body["parent_task_id"] = parent_task_id
    if project_id:
        body["project_id"] = project_id
    validate_task_send(body)

    subject = f"a2a.{target}.tasks.send"
    raw = crypto.wrap_payload(body, client.role)
    ack = await client.request_reply(subject, raw, timeout=timeout)
    if isinstance(ack, dict):
        try:
            ack = crypto.unwrap_dict(ack, expected_role=target)
        except crypto.CryptoError as e:
            log.warning("ack unwrap failed from %s: %s", target, e)
    return {"task_id": task_id, "target_role": target, "ack": ack}
