"""Substrate → A2A dual-write bridge (slice 3 card 143).

Existing tools (claim_task, complete_task, block_task, park_task,
resume_task) publish on `board.tasks.<d>.<state>` and friends. This
bridge mirrors each transition into the A2A canonical surface so the
AUDIT stream contains both flows. Agent-facing surface becomes
A2A-canonical; substrate stays for backward-compat.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from .lifecycle import is_terminal, map_substrate
from .worker import update_inflight, lookup_inflight_state


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def derive_task_id(slug: str, *, supplied: str | None = None) -> str:
    """Stable task_id for a given substrate slug.

    If a caller already minted a task_id (e.g. pull-mode dispatch
    embedded one in the task pending payload), prefer that; else use
    a deterministic prefix on slug so multiple ticks of the same task
    bridge to the same id.
    """
    if supplied:
        return supplied
    return f"a2a:{slug}"


async def mirror_substrate_to_a2a(
    client,
    substrate_state: str,
    slug: str,
    *,
    supplied_task_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> str | None:
    """Publish the matching A2A status event for a substrate transition.

    Returns the task_id used (caller may want to thread it onward).
    No-op + None when the substrate state has no A2A counterpart.
    """
    try:
        a2a_state, reason = map_substrate(substrate_state)
    except Exception:
        return None

    task_id = derive_task_id(slug, supplied=supplied_task_id)
    body: dict[str, Any] = {
        "task_id": task_id,
        "state": a2a_state,
        "by": client.role,
        "ts": _now_iso(),
        "from_substrate": substrate_state,
    }
    if reason:
        body["reason"] = reason
    if extra:
        body["extra"] = extra

    subject = f"a2a.{client.role}.tasks.{task_id}.status"
    from .. import crypto
    await client.publish(subject, crypto.wrap_payload(body, client.role))

    # Mirror in inflight KV — keeps consistent state for a2a_update_status
    # invocations that follow.
    await update_inflight(client, task_id, a2a_state, terminal=is_terminal(a2a_state))
    return task_id
