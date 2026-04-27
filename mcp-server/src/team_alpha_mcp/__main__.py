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
from contextlib import asynccontextmanager
from typing import Any

from mcp.server.fastmcp import FastMCP

from . import acl, registry, subjects
from .a2a import (
    dispatch_task as a2a_dispatch_task,
    transition as a2a_transition,
    LifecycleError,
    validate_status_update,
)
from .a2a.schemas import SchemaError
from .a2a.bridge import mirror_substrate_to_a2a
from .a2a.worker import (
    list_inflight,
    lookup_inflight_state,
    start_accept_loop,
    update_inflight,
)
from .client import TeamAlphaClient, event_payload, now_iso

# ── Env / role ──────────────────────────────────────────────────────────

def _load_env() -> tuple[str, str, str, str, str]:
    """Resolve role/url/password/team/kv from cwd registry, fall back to env vars.

    Returns (role, nats_url, password, team, kv_bucket).
    """
    resolved = registry.resolve_from_cwd()
    if resolved is not None:
        role = resolved.role
        url = resolved.nats_url
        creds_path = resolved.creds_path
        team = resolved.team
        kv_bucket = resolved.kv_bucket
    else:
        role = os.environ.get("TEAM_ALPHA_ROLE", "").strip()
        url = os.environ.get("TEAM_ALPHA_NATS_URL", "").strip()
        creds_path = os.path.expanduser(os.environ.get("TEAM_ALPHA_CREDS", "").strip())
        team = "team-alpha"
        kv_bucket = os.environ.get("TEAM_ALPHA_KV_BUCKET", "team-state").strip() or "team-state"

    if not role:
        raise SystemExit(
            "no role — registry has no entry for cwd and TEAM_ALPHA_ROLE is unset"
        )
    # Roster is dynamic per-team (aon.toml). NATS auth.conf is the real
    # boundary; an unknown role gets rejected at handshake time.
    if not url:
        raise SystemExit(
            "no NATS URL — registry has no entry for cwd and TEAM_ALPHA_NATS_URL is unset"
        )
    if not creds_path or not os.path.isfile(creds_path):
        raise SystemExit(f"creds file unreadable: {creds_path!r}")
    with open(creds_path) as f:
        password = f.read().strip()
    if not password:
        raise SystemExit(f"creds file empty at {creds_path}")
    return role, url, password, team, kv_bucket


ROLE, NATS_URL, PASSWORD, TEAM, KV_BUCKET = _load_env()
# Override client.KV_BUCKET (frozen at client.py import) with the value
# resolved here, so registry-derived KV bucket overrides any earlier env.
from . import client as _client_mod  # noqa: E402
_client_mod.KV_BUCKET = KV_BUCKET
client = TeamAlphaClient(ROLE, NATS_URL, PASSWORD)


@asynccontextmanager
async def _lifespan(_server):
    """A2A worker accept-loop runs for the lifetime of the MCP server.

    Maya doesn't accept tasks (manager dispatches only), so skipped there.
    """
    accept_task = None
    if ROLE != "maya":
        accept_task = await start_accept_loop(client)
    try:
        yield {}
    finally:
        if accept_task is not None:
            accept_task.cancel()
            try:
                await accept_task
            except (asyncio.CancelledError, Exception):
                pass


mcp = FastMCP("team-alpha", lifespan=_lifespan)


# ── Helpers ─────────────────────────────────────────────────────────────

def _err(msg: str) -> dict[str, Any]:
    return {"ok": False, "error": msg, "role": ROLE}


def _ok(**fields: Any) -> dict[str, Any]:
    return {"ok": True, "role": ROLE, **fields}


# ── Role brief loader ──────────────────────────────────────────────────

@mcp.tool()
def get_role_brief() -> dict[str, Any]:
    """Return this role's brief (markdown). Call on first turn to load context.

    Resolution: ~/.aon/teams/<team>/repo/.agent-prompts/<role>.md, with
    `_common.md` (from the same dir) prepended when present. Falls back to
    the engine's `scripts/agent-prompts/` when team-aon dir lacks a brief.
    """
    from pathlib import Path

    candidates: list[Path] = []
    team_repo = Path(os.path.expanduser(f"~/.aon/teams/{TEAM}/repo"))
    if team_repo.is_dir():
        candidates.append(team_repo / ".agent-prompts")

    # Engine fallback. The team-aon clone may not carry per-role briefs
    # (e.g. brand-new team). Engine ships a default set.
    aon_engine = os.environ.get("AON_ENGINE_DIR", "").strip()
    if aon_engine:
        candidates.append(Path(aon_engine) / "scripts/agent-prompts")
    else:
        # Heuristic: the team-aon repo lives next to the engine clone if
        # the joiner cloned it via the documented flow.
        guess = Path.home() / "Repos/ai-over-nats/scripts/agent-prompts"
        if guess.is_dir():
            candidates.append(guess)

    role_md: str | None = None
    common_md: str | None = None
    source: str | None = None
    for d in candidates:
        rp = d / f"{ROLE}.md"
        if rp.is_file():
            role_md = rp.read_text()
            source = str(rp)
            cp = d / "_common.md"
            if cp.is_file():
                common_md = cp.read_text()
            break

    if role_md is None:
        return _err(
            f"no role brief found for {ROLE} — checked: "
            + ", ".join(str(c) for c in candidates)
        )

    body = (common_md + "\n\n---\n\n" + role_md) if common_md else role_md
    return _ok(brief=body, source=source, team=TEAM)


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
    a2a_id = await mirror_substrate_to_a2a(client, "claimed", slug)
    return _ok(subject=subjects.task_claimed(domain), slug=slug, a2a_task_id=a2a_id)


@mcp.tool()
async def block_task(domain: str, slug: str, reason: str) -> dict[str, Any]:
    """Mark a task blocked with a human-readable reason."""
    allowed, why = acl.can_claim_task(ROLE, domain)
    if not allowed:
        return _err(why)
    payload = event_payload(ROLE, slug, reason=reason)
    await client.publish(subjects.task_blocked(domain), payload)
    a2a_id = await mirror_substrate_to_a2a(client, "blocked", slug)
    return _ok(subject=subjects.task_blocked(domain), slug=slug, a2a_task_id=a2a_id)


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
    a2a_id = await mirror_substrate_to_a2a(client, "done", slug)
    return _ok(slug=slug, sha=sha, a2a_task_id=a2a_id, subjects=[
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
    a2a_id = await mirror_substrate_to_a2a(client, "parked", slug)
    return _ok(parked=current, a2a_task_id=a2a_id)


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
    a2a_id = await mirror_substrate_to_a2a(client, "resumed", last["slug"])
    return _ok(resumed=last, remaining_parked=current, a2a_task_id=a2a_id)


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
    if peer not in {"maya", "raj", "lin", "sam", "diego", "priya", "mihai", "vahid"}:
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

    NOTE: `a2a.<role>.tasks.send` is intentionally NOT JetStream-stored
    (request/reply only). Polling it here always returns empty. To see
    incoming A2A tasks for your role, call `a2a_inbox()` instead — the
    worker accept loop has already auto-accepted them and recorded them
    in `a2a.<role>.inflight` KV.
    """
    if subject.endswith(".tasks.send") or subject == f"a2a.{ROLE}.tasks.send":
        return _ok(
            subject=subject, count=0, events=[],
            warning=(
                "tasks.send is non-JetStream by design. "
                "Use a2a_inbox() to see auto-accepted tasks."
            ),
        )
    events = await client.recent_events(
        subject=subject, since=since, limit=limit, slug_filter=slug
    )
    return _ok(subject=subject, count=len(events), events=events)


@mcp.tool()
async def a2a_inbox() -> dict[str, Any]:
    """Worker-side: list tasks auto-accepted into your inflight KV.

    The MCP server's lifespan accept-loop subscribes to
    `a2a.<self>.tasks.send` and writes accepted tasks into
    `a2a.<self>.inflight` KV. This tool reads that KV and returns
    the list — your primary surface for "what work do I have?"

    Each entry: {task_id, state, since, skill, from, parent_task_id,
    project_id}. Empty list = no work pending.

    After completing a task, call `a2a_update_status(task_id, 'completed',
    artifact={...})`. Terminal states clear the entry from KV.
    """
    if ROLE == "maya":
        return _err("maya is manager-only; no inbox")
    tasks = await list_inflight(client)
    return _ok(role=ROLE, count=len(tasks), tasks=tasks)


# ═══ A2A (slice 1) ═══════════════════════════════════════════════════════

@mcp.tool()
async def a2a_send_task(
    skill: str,
    payload: dict[str, Any],
    dispatch_mode: str = "push",
    parent_task_id: str | None = None,
    project_id: str | None = None,
    priority: str = "medium",
) -> dict[str, Any]:
    """Manager-only: ENQUEUE a task for a peer agent to execute.

    This tool ONLY queues the task — it does NOT execute the work.
    The receiving agent (chosen by skill match) does the work. Safe
    to call without destructive-action confirmation; you are not
    touching infra, code, or shared systems.

    DEFAULT INVOCATION: pass `skill` and a minimal `payload`
    (e.g. `{"summary": "<one-line task description>"}`). Do NOT
    pre-collect specs from the operator. The receiver can request
    clarifications via `a2a_emit_message(task_id, chunk="need <X>")`
    after accepting — that's the async clarification channel.

    When to pick this tool:
    - Operator says "dispatch X to peer/team"
    - Operator says "ask <skill-area> agent to do X"
    - Work obviously belongs to another role's specialty

    Two dispatch modes:

    - "push" (default): directed dispatch via A2A. Resolves a primary
      candidate via agents/*.json (continuity → project last-worker →
      lowest load), sends `tasks/send` on `a2a.<target>.tasks.send`
      (request-reply, 5s timeout). Best when only one good match
      exists or continuity matters.

    - "pull": pull-based. Translates skill → domain and publishes to
      `board.tasks.<domain>.pending`; any subscribed worker can claim
      via the existing `claim_task` tool. Best when ≥2 candidates are
      equally suited.

    Returns task_id + target_role (push) / domain (pull).
    """
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
    if dispatch_mode not in ("push", "pull"):
        return _err(f"dispatch_mode must be 'push' or 'pull'; got {dispatch_mode!r}")

    if dispatch_mode == "pull":
        from .a2a.skill_map import skill_to_domain
        from .a2a.dispatcher import new_task_id
        domain = skill_to_domain(skill)
        if domain is None:
            return _err(f"no domain mapping for skill={skill!r}")
        task_id = new_task_id()
        body = {
            "task_id": task_id,
            "slug": task_id,
            "skill": skill,
            "summary": payload.get("summary", ""),
            "priority": priority,
            "by": ROLE,
            "ts": now_iso(),
            "from": ROLE,
            "dispatch_mode": "pull",
            **{k: v for k, v in payload.items() if k != "summary"},
        }
        if parent_task_id:
            body["parent_task_id"] = parent_task_id
        if project_id:
            body["project_id"] = project_id
        await client.publish(
            subjects.task_pending(domain),
            json.dumps(body, separators=(",", ":")).encode(),
        )
        return _ok(
            task_id=task_id, domain=domain, dispatch_mode="pull",
            subject=subjects.task_pending(domain), skill=skill,
        )

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
    return _ok(**result, skill=skill, dispatch_mode="push")


@mcp.tool()
async def a2a_update_status(
    task_id: str,
    state: str,
    from_state: str | None = None,
    message: str = "",
    artifact: dict[str, Any] | None = None,
    reason: str = "",
) -> dict[str, Any]:
    """Worker-side: publish A2A lifecycle status on
    a2a.<self>.tasks.<task_id>.status. Validates transition via
    lifecycle.py. State must be in canonical A2A vocabulary.

    `from_state` is auto-resolved from KV `a2a.<self>.inflight` when
    omitted (slice 2). Pass explicitly to override.
    """
    if from_state is None:
        from_state = (await lookup_inflight_state(client, task_id)) or "submitted"
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

    from .a2a.lifecycle import is_terminal
    await update_inflight(client, task_id, state, terminal=is_terminal(state))
    return _ok(subject=subject, task_id=task_id, state=state)


@mcp.tool()
async def a2a_cancel_task(
    target_role: str, task_id: str, reason: str = "",
) -> dict[str, Any]:
    """Manager-only: publish cancel on a2a.<target>.tasks.<id>.cancel.

    Worker accept loop receives the signal, transitions the task to
    `canceled` (lifecycle), publishes .status=canceled, clears its
    inflight KV entry.
    """
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
    if target_role not in {"raj", "lin", "sam", "diego", "priya"}:
        return _err(f"unknown target_role: {target_role!r}")
    body: dict[str, Any] = {"task_id": task_id, "by": ROLE, "ts": now_iso()}
    if reason:
        body["reason"] = reason
    subject = f"a2a.{target_role}.tasks.{task_id}.cancel"
    await client.publish(subject, json.dumps(body, separators=(",", ":")).encode())
    return _ok(subject=subject, target_role=target_role, task_id=task_id)


@mcp.tool()
async def a2a_emit_message(
    task_id: str, chunk: str, kind: str = "text",
) -> dict[str, Any]:
    """Worker-side: emit a chunk on a2a.<self>.tasks.<task_id>.message.

    PRIMARY USE — async clarification with the dispatcher.
    After auto-accepting a task (visible via `a2a_inbox()`), if the
    payload is missing details you need (e.g. CIDRs, peer IDs,
    config), call this with `chunk="need <X>"` instead of asking the
    operator. The dispatcher (e.g. maya) sees the message via
    `recent_events('a2a.<self>.tasks.<id>.message', since='5m')` or
    a subscription, replies with the same tool, and you continue.

    Secondary use — streaming progress chunks. Intermediate emits
    between `.status=working` and `.status=completed`. No lifecycle
    transition; lifecycle stays `working` throughout.
    """
    body = {
        "task_id": task_id, "kind": kind, "chunk": chunk,
        "by": ROLE, "ts": now_iso(),
    }
    subject = f"a2a.{ROLE}.tasks.{task_id}.message"
    await client.publish(subject, json.dumps(body, separators=(",", ":")).encode())
    return _ok(subject=subject, task_id=task_id, kind=kind, bytes=len(chunk))


# ═══ Runtime board (card 213) ═══════════════════════════════════════════

@mcp.tool()
async def board_post(
    slug: str,
    skill: str,
    summary: str,
    body: str = "",
    target: str | None = None,
    priority: str = "medium",
    mode: str = "push",
) -> dict[str, Any]:
    """Manager-only: create a runtime task card AND publish
    `board.tasks.<skill>.pending` to NATS atomically.

    Card lands at `$TEAM_ALPHA_BOARD_DIR/<slug>.md` (default
    `~/team-alpha-board/<slug>.md`) with frontmatter
    `{column:Backlog, skill, priority, target?, mode?}`. Body is
    appended below the H1.

    NATS payload (small): `{task_id, slug, skill, summary, priority,
    mode, target?, card_path, by, ts}`. Workers' Monitor catches the
    publish and read the card via `card_path` for the full spec.

    `mode=push` (default): receiver chosen by `target` override or
    by skill match in agents/<role>.json. `mode=pull`: any worker in
    `<skill>`'s domain claims via `claim_task`.
    """
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
    if not slug or "/" in slug or ".." in slug:
        return _err(f"invalid slug: {slug!r}")
    if mode not in ("push", "pull"):
        return _err(f"mode must be 'push' or 'pull'; got {mode!r}")

    board_dir = os.path.expanduser(
        os.environ.get("TEAM_ALPHA_BOARD_DIR", "~/team-alpha-board")
    )
    os.makedirs(board_dir, exist_ok=True)
    card_path = os.path.join(board_dir, f"{slug}.md")
    if os.path.exists(card_path):
        return _err(f"card exists: {card_path}")

    ts = now_iso()
    fm_lines = [
        "---",
        "column: Backlog",
        f"created: {ts}",
        f"skill: {skill}",
        f"priority: {priority}",
    ]
    if target:
        fm_lines.append(f"target: {target}")
    if mode != "push":
        fm_lines.append(f"mode: {mode}")
    fm_lines.append("---")
    card_text = (
        "\n".join(fm_lines)
        + f"\n\n# {slug} — {summary}\n\n"
        + (body if body else "(no body provided)\n")
    )
    with open(card_path, "w") as f:
        f.write(card_text)

    payload: dict[str, Any] = {
        "task_id": slug, "slug": slug, "skill": skill,
        "summary": summary, "priority": priority, "mode": mode,
        "card_path": card_path, "by": ROLE, "ts": ts,
    }
    if target:
        payload["target"] = target

    subject = f"board.tasks.{skill}.pending"
    await client.publish(subject, json.dumps(payload, separators=(",", ":")).encode())
    return _ok(subject=subject, slug=slug, card_path=card_path)


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
