"""team-alpha MCP server — typed tools wrapping the NATS substrate.

Run:
    TEAM_ALPHA_ROLE=lin \
    TEAM_ALPHA_NATS_URL=nats://nats.team-alpha.corp:4222 \
    TEAM_ALPHA_CREDS=~/.team-alpha/lin.password \
    team-alpha-mcp [--transport stdio|http]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
from typing import Any

from mcp.server.fastmcp import FastMCP

from . import acl, subjects
from .a2a import (
    dispatch_task as a2a_dispatch_task,
    transition as a2a_transition,
    LifecycleError,
    validate_status_update,
)
from .a2a.schemas import SchemaError
from .client import TeamAlphaClient, event_payload, now_iso

# ── Env / role ──────────────────────────────────────────────────────────

def _load_env() -> tuple[str, str, str]:
    role = os.environ.get("TEAM_ALPHA_ROLE", "").strip()
    if role not in {"maya", "raj", "lin", "sam", "diego", "priya"}:
        raise SystemExit(
            "TEAM_ALPHA_ROLE must be one of {maya,raj,lin,sam,diego,priya}; "
            f"got {role!r}"
        )
    url = os.environ.get("TEAM_ALPHA_NATS_URL", "").strip()
    if not url:
        raise SystemExit("TEAM_ALPHA_NATS_URL not set")
    creds_path = os.path.expanduser(os.environ.get("TEAM_ALPHA_CREDS", "").strip())
    if not creds_path or not os.path.isfile(creds_path):
        raise SystemExit(f"TEAM_ALPHA_CREDS file unreadable: {creds_path!r}")
    with open(creds_path) as f:
        password = f.read().strip()
    if not password:
        raise SystemExit(f"TEAM_ALPHA_CREDS empty at {creds_path}")
    return role, url, password


ROLE, NATS_URL, PASSWORD = _load_env()
client = TeamAlphaClient(ROLE, NATS_URL, PASSWORD)

mcp = FastMCP("team-alpha")


# ── Helpers ─────────────────────────────────────────────────────────────

def _err(msg: str) -> dict[str, Any]:
    return {"ok": False, "error": msg, "role": ROLE}


def _ok(**fields: Any) -> dict[str, Any]:
    return {"ok": True, "role": ROLE, **fields}


# ═══ TASKS ═══════════════════════════════════════════════════════════════

@mcp.tool()
async def claim_task(domain: str, slug: str) -> dict[str, Any]:
    """Claim a production task. Publishes board.tasks.<domain>.claimed and
    updates KV agent.<role>.load. Returns ok=False if your role cannot claim
    in that domain (try claim_learning instead)."""
    allowed, why = acl.can_claim_task(ROLE, domain)
    if not allowed:
        return _err(why)
    payload = event_payload(ROLE, slug)
    await client.publish(subjects.task_claimed(domain), payload)
    await client.kv_put(
        subjects.kv_agent_load(ROLE),
        {"capacity": "active", "current_tasks": 1, "slug": slug, "since": now_iso()},
    )
    return _ok(subject=subjects.task_claimed(domain), slug=slug)


@mcp.tool()
async def block_task(domain: str, slug: str, reason: str) -> dict[str, Any]:
    """Mark a task blocked with a human-readable reason."""
    allowed, why = acl.can_claim_task(ROLE, domain)
    if not allowed:
        return _err(why)
    payload = event_payload(ROLE, slug, reason=reason)
    await client.publish(subjects.task_blocked(domain), payload)
    return _ok(subject=subjects.task_blocked(domain), slug=slug)


@mcp.tool()
async def complete_task(
    domain: str, slug: str, sha: str, summary: str = ""
) -> dict[str, Any]:
    """Publish .done on the task board AND .shipped on the results board."""
    allowed, why = acl.can_post_results(ROLE, domain)
    if not allowed:
        return _err(why)
    done_p = event_payload(ROLE, slug, sha=sha)
    ship_p = event_payload(ROLE, slug, sha=sha, summary=summary)
    await client.publish(subjects.task_done(domain), done_p)
    await client.publish(subjects.results(domain, "shipped"), ship_p)
    return _ok(slug=slug, sha=sha, subjects=[
        subjects.task_done(domain), subjects.results(domain, "shipped"),
    ])


@mcp.tool()
async def progress_task(domain: str, slug: str, note: str) -> dict[str, Any]:
    """Optional milestone marker — tests green, PR opened, etc."""
    payload = event_payload(ROLE, slug, note=note)
    await client.publish(subjects.task_progress(domain), payload)
    return _ok(subject=subjects.task_progress(domain), slug=slug)


@mcp.tool()
async def post_task(
    domain: str, slug: str, summary: str, priority: str = "medium"
) -> dict[str, Any]:
    """Manager-only: post a task to the production board."""
    allowed, why = acl.can_post_task(ROLE)
    if not allowed:
        return _err(why)
    payload = event_payload(
        ROLE, slug, task_id=slug, summary=summary, priority=priority
    )
    await client.publish(subjects.task_pending(domain), payload)
    return _ok(subject=subjects.task_pending(domain), slug=slug)


# ═══ PARK / RESUME (preemption) ══════════════════════════════════════════

@mcp.tool()
async def park_task(slug: str, branch: str, reason: str = "preempt") -> dict[str, Any]:
    """Park current task: append to KV parked stack + emit parked event."""
    key = subjects.kv_agent_parked(ROLE)
    current = (await client.kv_get(key)) or []
    if not isinstance(current, list):
        current = []
    current.append({"slug": slug, "branch": branch, "since": now_iso(), "reason": reason})
    await client.kv_put(key, current)
    payload = event_payload(ROLE, slug, reason=reason)
    # parked event uses the task domain in subject — caller must include via
    # slug naming convention or we publish a generic parked subject. Here we
    # use a domain-agnostic state subject for the event:
    await client.publish(f"state.agent.{ROLE}.parked", payload)
    return _ok(parked=current)


@mcp.tool()
async def resume_task() -> dict[str, Any]:
    """Pop the latest parked entry (LIFO) and emit resumed event."""
    key = subjects.kv_agent_parked(ROLE)
    current = (await client.kv_get(key)) or []
    if not isinstance(current, list) or not current:
        return _err("nothing parked")
    last = current.pop()
    await client.kv_put(key, current)
    payload = event_payload(ROLE, last["slug"], from_park=True)
    await client.publish(f"state.agent.{ROLE}.resumed", payload)
    return _ok(resumed=last, remaining_parked=current)


# ═══ LEARNING ════════════════════════════════════════════════════════════

@mcp.tool()
async def claim_learning(domain: str, slug: str) -> dict[str, Any]:
    """Claim a learning-track task (mentor-paired, scoped)."""
    allowed, why = acl.can_claim_learning(ROLE, domain)
    if not allowed:
        return _err(why)
    payload = event_payload(ROLE, slug)
    await client.publish(subjects.learn_claimed(domain), payload)
    return _ok(subject=subjects.learn_claimed(domain), slug=slug)


@mcp.tool()
async def offer_mentoring(
    domain: str, hours: int, topics: list[str]
) -> dict[str, Any]:
    """Senior-only: announce mentoring availability."""
    allowed, why = acl.can_offer_mentoring(ROLE, domain)
    if not allowed:
        return _err(why)
    slug = f"mentor-{ROLE}-{domain}-{int(asyncio.get_event_loop().time()*1000)}"
    payload = event_payload(
        ROLE, slug, mentor=ROLE, domain=domain, hours=hours, topics=topics
    )
    await client.publish(subjects.learn_mentoring(domain), payload)
    return _ok(subject=subjects.learn_mentoring(domain), slug=slug)


@mcp.tool()
async def post_learning(
    domain: str, slug: str, summary: str, scope_hours: int, mentor: str
) -> dict[str, Any]:
    """Senior + manager: post a learning task with scope and mentor."""
    if ROLE not in ("raj", "maya"):
        return _err(f"role={ROLE} cannot post learning tasks (senior/manager only)")
    payload = event_payload(
        ROLE, slug, task_id=slug, summary=summary,
        scope_hours=scope_hours, mentor=mentor, priority="low",
    )
    await client.publish(subjects.learn_pending(domain), payload)
    return _ok(subject=subjects.learn_pending(domain), slug=slug)


# ═══ COMMS ═══════════════════════════════════════════════════════════════

@mcp.tool()
async def dm(
    peer: str, type: str, message: str = "",
    extra: dict[str, Any] | None = None,
    request_reply: bool = False,
) -> dict[str, Any]:
    """DM another role's inbox. Optionally request/reply with 5s timeout.

    Flood-guarded (card 95): refuses 6th+ DM to same peer within 60s. Reset
    on reply. Use ASK chain — DM peer once, escalate to maya, alert no_human.
    Never retry to the same peer.
    """
    if peer not in {"maya", "raj", "lin", "sam", "diego", "priya"}:
        return _err(f"unknown peer role: {peer!r}")
    allowed, why = client.dm_check_flood(peer)
    if not allowed:
        return _err(why)
    payload = event_payload(
        ROLE, slug=f"dm-{type}-{int(asyncio.get_event_loop().time()*1000)}",
        type=type, from_role=ROLE, message=message, **(extra or {}),
    )
    subj = subjects.agent_inbox(peer)
    if request_reply:
        reply = await client.request_reply(subj, payload)
        if reply is not None:
            client.dm_mark_reply(peer)
        return _ok(reply=reply)
    await client.publish(subj, payload)
    return _ok(subject=subj)


@mcp.tool()
async def dm_reply_received(peer: str) -> dict[str, Any]:
    """Mark that a peer replied — resets the flood-guard window for that peer.

    Call this when you observe a reply on your own inbox from `peer` so
    subsequent DMs don't false-positive the flood guard."""
    client.dm_mark_reply(peer)
    return _ok(peer=peer, reset=True)


@mcp.tool()
async def broadcast_standup(agenda: list[str], time: str = "10:00") -> dict[str, Any]:
    """Manager-only: kick off standup."""
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
    slug = f"standup-{int(asyncio.get_event_loop().time()*1000)}"
    payload = event_payload(ROLE, slug, time=time, agenda=agenda)
    await client.publish(subjects.BROADCAST_STANDUP, payload)
    return _ok(subject=subjects.BROADCAST_STANDUP)


@mcp.tool()
async def broadcast_incident(
    severity: str, system: str, status: str,
    incident_id: str | None = None, root_cause: str = "",
) -> dict[str, Any]:
    """Anyone can declare/update an incident."""
    iid = incident_id or f"inc-{int(asyncio.get_event_loop().time()*1000)}"
    body: dict[str, Any] = {
        "incident_id": iid, "severity": severity, "system": system,
        "owner": ROLE, "status": status,
    }
    if root_cause:
        body["root_cause"] = root_cause
    payload = event_payload(ROLE, slug=iid, **body)
    await client.publish(subjects.BROADCAST_INCIDENTS, payload)
    return _ok(subject=subjects.BROADCAST_INCIDENTS, incident_id=iid)


@mcp.tool()
async def broadcast_announcement(title: str, body: str) -> dict[str, Any]:
    """Manager-only: team-wide announcement."""
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
    slug = f"announce-{int(asyncio.get_event_loop().time()*1000)}"
    payload = event_payload(ROLE, slug, title=title, body=body)
    await client.publish(subjects.BROADCAST_ANNOUNCE, payload)
    return _ok(subject=subjects.BROADCAST_ANNOUNCE)


# ═══ STATE / KV ══════════════════════════════════════════════════════════

@mcp.tool()
async def set_load(capacity: str, current_tasks: int = 0) -> dict[str, Any]:
    """Update your own load entry (idle | active | busy)."""
    if capacity not in ("idle", "active", "busy"):
        return _err(f"capacity must be one of idle/active/busy; got {capacity!r}")
    body = {"capacity": capacity, "current_tasks": current_tasks, "since": now_iso()}
    rev = await client.kv_put(subjects.kv_agent_load(ROLE), body)
    return _ok(revision=rev, value=body)


@mcp.tool()
async def set_human(
    status: str, scope: list[str] | None = None,
    until: str | None = None, reason: str = "",
) -> dict[str, Any]:
    """Update your own human-availability flag."""
    if status not in ("available", "busy", "offline", "delegated"):
        return _err(f"status invalid: {status!r}")
    body: dict[str, Any] = {"status": status, "since": now_iso()}
    if reason:
        body["reason"] = reason
    if status == "delegated":
        body["scope"] = scope or []
        if until:
            body["until"] = until
    rev = await client.kv_put(subjects.kv_agent_human(ROLE), body)
    await client.publish(subjects.state_agent_human(ROLE), event_payload(ROLE, slug=ROLE, **body))
    return _ok(revision=rev, value=body)


@mcp.tool()
async def set_policy(name: str, value: dict[str, Any]) -> dict[str, Any]:
    """Manager-only: flip a team-wide policy KV (e.g. delegated, hitl)."""
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
    rev = await client.kv_put(subjects.kv_policy(name), {**value, "set_by": ROLE, "ts": now_iso()})
    await client.publish(
        subjects.state_policy(name),
        event_payload(ROLE, slug=name, **value),
    )
    return _ok(revision=rev)


@mcp.tool()
async def read_team_state(key: str) -> dict[str, Any]:
    """Read any KV key under team-state."""
    val = await client.kv_get(key)
    return _ok(key=key, value=val)


# ═══ REPLAY ══════════════════════════════════════════════════════════════

@mcp.tool()
async def recent_events(
    subject: str, slug: str | None = None,
    since: str = "60s", limit: int = 500,
) -> dict[str, Any]:
    """Replay recent events from AUDIT for a subject pattern.

    Examples:
      recent_events('board.tasks.terraform.claimed', since='5m')
      recent_events('agents.maya.events', slug='handshake')
      recent_events('state.alert.>', since='1h')
    """
    events = await client.recent_events(
        subject=subject, since=since, limit=limit, slug_filter=slug
    )
    return _ok(subject=subject, count=len(events), events=events)


# ═══ A2A (slice 1) ═══════════════════════════════════════════════════════

@mcp.tool()
async def a2a_send_task(
    skill: str,
    payload: dict[str, Any],
    parent_task_id: str | None = None,
    project_id: str | None = None,
    priority: str = "medium",
) -> dict[str, Any]:
    """Manager-only (slice 1): dispatch an A2A task by skill match.

    Resolves a primary candidate via agents/*.json. Tiebreak order:
    continuity (parent_task_id) → project last-worker → lowest load.
    Sends `tasks/send` on `a2a.<target>.tasks.send` (request-reply,
    5s timeout). Returns target_role + task_id + worker ack.
    """
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
    try:
        result = await a2a_dispatch_task(
            client, skill=skill, payload=payload,
            parent_task_id=parent_task_id, project_id=project_id,
            priority=priority,
        )
    except SchemaError as e:
        return _err(f"schema: {e}")
    except Exception as e:
        return _err(f"dispatch: {e}")
    return _ok(**result, skill=skill)


@mcp.tool()
async def a2a_update_status(
    task_id: str,
    state: str,
    from_state: str = "submitted",
    message: str = "",
    artifact: dict[str, Any] | None = None,
    reason: str = "",
) -> dict[str, Any]:
    """Worker-side: publish A2A lifecycle status on
    a2a.<self>.tasks.<task_id>.status. Validates transition via
    lifecycle.py. State must be in canonical A2A vocabulary.

    `from_state` is the worker's last-known state for this task, used
    for transition validation. Caller tracks; slice 2 adds server-side
    state KV.
    """
    try:
        a2a_transition(from_state, state)
    except LifecycleError as e:
        return _err(str(e))

    body: dict[str, Any] = {"task_id": task_id, "state": state, "by": ROLE}
    if message:
        body["message"] = message
    if artifact:
        body["artifact"] = artifact
    if reason:
        body["reason"] = reason
    try:
        validate_status_update(body)
    except SchemaError as e:
        return _err(f"schema: {e}")

    body["ts"] = now_iso()
    subject = f"a2a.{ROLE}.tasks.{task_id}.status"
    payload = json.dumps(body, separators=(",", ":")).encode()
    await client.publish(subject, payload)
    return _ok(subject=subject, task_id=task_id, state=state)


# ═══ ENTRY ═══════════════════════════════════════════════════════════════

def main() -> None:
    parser = argparse.ArgumentParser(prog="team-alpha-mcp")
    parser.add_argument(
        "--transport",
        choices=("stdio", "http"),
        default="stdio",
        help="MCP transport (default: stdio for Claude Code registration)",
    )
    parser.add_argument(
        "--port", type=int, default=8765, help="HTTP port (transport=http)"
    )
    args = parser.parse_args()

    if args.transport == "stdio":
        mcp.run("stdio")
    else:
        # FastMCP HTTP transport (SSE-based).
        mcp.run("sse", port=args.port)


if __name__ == "__main__":
    main()
