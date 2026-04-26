"""A2A worker auto-accept loop (slice 2 card 131).

When the MCP server starts under a worker role, this subscribes to
`a2a.<role>.tasks.send`, validates incoming tasks/send requests,
auto-acks via NATS reply, publishes initial `.status = working`,
and records the task in KV `a2a.<role>.inflight` so subsequent
`a2a_update_status` calls can resolve `from_state` server-side.
"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from .cards import card_skill_tier, load_card
from .lifecycle import transition
from .schemas import SchemaError, validate_task_send

log = logging.getLogger(__name__)


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def inflight_key(role: str) -> str:
    return f"a2a.{role}.inflight"


async def _record_inflight(client, task_id: str, payload: dict) -> None:
    key = inflight_key(client.role)
    current = (await client.kv_get(key)) or {}
    if not isinstance(current, dict):
        current = {}
    current[task_id] = {
        "state": "working",
        "since": _now_iso(),
        "skill": payload.get("skill"),
        "from": payload.get("from"),
        "parent_task_id": payload.get("parent_task_id"),
        "project_id": payload.get("project_id"),
    }
    await client.kv_put(key, current)


async def _publish_status(
    client, task_id: str, state: str, *, reason: str = ""
) -> None:
    body: dict[str, Any] = {
        "task_id": task_id, "state": state, "by": client.role, "ts": _now_iso(),
    }
    if reason:
        body["reason"] = reason
    subject = f"a2a.{client.role}.tasks.{task_id}.status"
    await client.publish(subject, json.dumps(body, separators=(",", ":")).encode())


async def _handle_send(client, msg) -> None:
    """One incoming a2a.<self>.tasks.send request."""
    reply_to = msg.reply
    try:
        body = json.loads(msg.data.decode()) if msg.data else {}
    except Exception as e:
        if reply_to:
            await client.publish(reply_to, _err_reply(f"bad json: {e}"))
        return

    try:
        validate_task_send(body)
    except SchemaError as e:
        if reply_to:
            await client.publish(reply_to, _err_reply(f"schema: {e}"))
        return

    task_id = body["task_id"]
    skill = body["skill"]

    # Defensive skill-match (slice-1 honor system; trust but verify own card).
    own_tier = card_skill_tier(client.role, skill)
    if own_tier is None:
        if reply_to:
            await client.publish(
                reply_to, _err_reply(
                    f"role={client.role} does not advertise skill={skill!r}"
                )
            )
        return

    # Lifecycle: submitted → working
    try:
        transition("submitted", "working")
    except Exception as e:
        if reply_to:
            await client.publish(reply_to, _err_reply(f"lifecycle: {e}"))
        return

    await _record_inflight(client, task_id, body)
    await _publish_status(client, task_id, "working")

    if reply_to:
        ack = {
            "ok": True, "task_id": task_id,
            "accepted_by": client.role, "tier": own_tier,
        }
        await client.publish(reply_to, json.dumps(ack).encode())


def _err_reply(msg: str) -> bytes:
    return json.dumps({"ok": False, "error": msg}).encode()


async def start_accept_loop(client) -> asyncio.Task:
    """Subscribe to a2a.<role>.tasks.send for the lifetime of the process.

    Returns the asyncio Task; caller cancels on shutdown.
    """
    nc = await client.nc()
    subject = f"a2a.{client.role}.tasks.send"

    async def handler(msg):
        try:
            await _handle_send(client, msg)
        except Exception as e:  # noqa: BLE001
            log.exception("a2a accept-loop error: %s", e)

    sub = await nc.subscribe(subject, cb=handler)
    log.info("a2a accept-loop subscribed: %s", subject)

    async def keep_alive() -> None:
        try:
            while True:
                await asyncio.sleep(3600)
        except asyncio.CancelledError:
            await sub.unsubscribe()
            raise

    return asyncio.create_task(keep_alive(), name=f"a2a-accept-{client.role}")


async def lookup_inflight_state(client, task_id: str) -> str | None:
    """Return current state for `task_id` from inflight KV, or None."""
    val = await client.kv_get(inflight_key(client.role))
    if not isinstance(val, dict):
        return None
    entry = val.get(task_id)
    if not isinstance(entry, dict):
        return None
    return entry.get("state")


async def update_inflight(
    client, task_id: str, new_state: str, *, terminal: bool
) -> None:
    """Move task to `new_state` in KV; remove if terminal."""
    key = inflight_key(client.role)
    val = (await client.kv_get(key)) or {}
    if not isinstance(val, dict):
        val = {}
    if terminal:
        val.pop(task_id, None)
    elif task_id in val and isinstance(val[task_id], dict):
        val[task_id]["state"] = new_state
        val[task_id]["since"] = _now_iso()
    else:
        val[task_id] = {"state": new_state, "since": _now_iso()}
    await client.kv_put(key, val)
