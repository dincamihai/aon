"""team-alpha MCP server — typed tools wrapping the NATS substrate.

Run:
    AON_ROLE=lin \
    AON_NATS_URL=nats://nats.team-alpha.corp:4222 \
    AON_CREDS=~/.team-alpha/lin.password \
    team-alpha-mcp [--transport stdio|http]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import tomllib
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP
from nats import connect as nats_connect

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

def _find_team_toml(team: str) -> Path | None:
    """Locate aon.toml for team. Checks ~/.aon registry path first (operator
    machines), then cwd and its parents (VM agents — worktree IS the repo)."""
    registry_path = Path(os.path.expanduser(f"~/.aon/teams/{team}/repo")) / "aon.toml"
    if registry_path.is_file():
        return registry_path
    # cwd fallback — in VM the agent's cwd is the cloned team worktree.
    cwd = Path.cwd()
    for candidate in [cwd, *cwd.parents]:
        p = candidate / "aon.toml"
        if p.is_file():
            return p
    return None


def _load_env() -> tuple[str, str, str, str, str, str]:
    """Resolve role/url/creds_path/team/kv/subject_prefix from cwd registry, fall back to env vars.

    AON_ROLE env var wins over registry when set — it is injected by
    `aon launch` via `exec env AON_ROLE=<role>` and identifies the
    launched agent. Multiple agents may share one work-repo (registry
    is path→role 1:1), so env var is the per-process authority.

    Returns (role, nats_url, creds_path, team, kv_bucket, subject_prefix).
    """
    resolved = registry.resolve_from_cwd()
    if resolved is not None:
        role = resolved.role
        url = resolved.nats_url
        creds_path = resolved.creds_path
        team = resolved.team
        kv_bucket = resolved.kv_bucket
    else:
        role = os.environ.get("AON_ROLE", "").strip()
        url = os.environ.get("AON_NATS_URL", "").strip()
        creds_path = os.path.expanduser(os.environ.get("AON_CREDS", "").strip())
        team = os.environ.get("AON_TEAM", "team-alpha").strip() or "team-alpha"
        kv_bucket = os.environ.get("AON_KV_BUCKET", "team-state").strip() or "team-state"

    # Load subject_prefix from team aon.toml
    subject_prefix = ""
    toml_path = _find_team_toml(team)
    if toml_path is not None and toml_path.is_file():
        try:
            data = tomllib.loads(toml_path.read_text())
            subject_prefix = data.get("team", {}).get("subject_prefix", "").strip()
        except Exception:
            pass

    # AON_ROLE env wins — set by `aon launch`, must not be clobbered by
    # a stale registry entry when multiple agents share one work-repo.
    # AON_CREDS only applies as fallback when registry did not resolve;
    # registry-resolved creds path is authoritative.
    env_role = os.environ.get("AON_ROLE", "").strip()
    if env_role:
        if env_role != role and role:
            print(
                f"[aon-mcp] warn: AON_ROLE={env_role} overrides registry role={role}",
                file=sys.stderr,
            )
        role = env_role
    if resolved is None:
        env_creds = os.environ.get("AON_CREDS", "").strip()
        if env_creds:
            creds_path = os.path.expanduser(env_creds)

    if not role:
        raise SystemExit(
            "no role — registry has no entry for cwd and AON_ROLE is unset"
        )
    # Roster is dynamic per-team (aon.toml). NATS account is the real
    # boundary; an unknown role gets rejected at handshake time.
    if not url:
        raise SystemExit(
            "no NATS URL — registry has no entry for cwd and AON_NATS_URL is unset"
        )
    if not creds_path or not os.path.isfile(creds_path):
        raise SystemExit(f"creds file unreadable: {creds_path!r}")
    return role, url, creds_path, team, kv_bucket, subject_prefix


def _load_roster(team: str, kind: str | None = None) -> set[str]:
    """Read [[roles]] name from team aon.toml.
    If kind set, filter by kind (e.g. 'manager')."""
    toml_path = _find_team_toml(team)
    if toml_path is None or not toml_path.is_file():
        return set()
    try:
        data = tomllib.loads(toml_path.read_text())
        roles = data.get("roles", [])
        if not isinstance(roles, list):
            return set()
        if kind:
            return {r["name"] for r in roles if isinstance(r, dict) and r.get("kind") == kind and "name" in r}
        return {r["name"] for r in roles if isinstance(r, dict) and "name" in r}
    except Exception:
        return set()


ROLE, NATS_URL, CREDS_PATH, TEAM, KV_BUCKET, SUBJECT_PREFIX = _load_env()
subjects.set_prefix(SUBJECT_PREFIX)
ROSTER = _load_roster(TEAM)
# Set manager roles on acl so broadcast/post-task checks work.
_MANAGERS = _load_roster(TEAM, kind="manager")
acl.set_managers(_MANAGERS)
# Override client.KV_BUCKET (frozen at client.py import) with the value
# resolved here, so registry-derived KV bucket overrides any earlier env.
from . import client as _client_mod  # noqa: E402
_client_mod.KV_BUCKET = KV_BUCKET
client = TeamAlphaClient(ROLE, NATS_URL, CREDS_PATH)


logger = logging.getLogger(__name__)

_AUTH_KEYWORDS = ("authorization", "auth", "jwt", "credentials", "user authentication")
_TRANSIENT_KEYWORDS = ("connect", "no route", "i/o timeout", "refused", "no servers", "timeout")


def _is_auth_err(msg: str) -> bool:
    return any(w in msg.lower() for w in _AUTH_KEYWORDS)


_A2A_DISC_STREAM = "A2A_DISC"
_CARD_REFRESH_INTERVAL = 300
_CARD_REFRESH_WARN_AFTER = 3


async def _publish_own_card(nc) -> bool:
    """Publish own agent card to A2A_DISC stream + KV agents.<role>.card.

    Called on startup and periodically to heal stale entries after reconnects.
    Returns True if at least one destination accepted the publish, False if both failed.
    Individual failures are logged at DEBUG so they never block startup.
    """
    from .a2a.cards import own_card_path
    card_path = own_card_path(ROLE)
    if card_path is None:
        return True  # no card to publish — not a failure
    card_bytes = await asyncio.to_thread(card_path.read_bytes)
    disc_subject = subjects.a2a_discovery(ROLE)
    js = nc.jetstream()
    published = 0
    # A2A_DISC stream (max-msgs-per-subject=1 — latest wins)
    try:
        await js.publish(disc_subject, card_bytes)
        published += 1
    except Exception as e:
        logger.debug("card_disc_publish_failed role=%s subject=%s: %s", ROLE, disc_subject, e)
    # KV for get_peer_cards() primary path
    try:
        kv = await js.key_value(KV_BUCKET)
        await kv.put(f"agents.{ROLE}.card", card_bytes)
        published += 1
    except Exception as e:
        logger.debug("card_kv_publish_failed role=%s: %s", ROLE, e)
    return published > 0


async def _card_refresh_loop() -> None:
    """Re-publish own card every _CARD_REFRESH_INTERVAL seconds so A2A_DISC stays fresh."""
    consecutive_failures = 0
    while True:
        await asyncio.sleep(_CARD_REFRESH_INTERVAL)
        try:
            nc = await client.nc()
            ok = await _publish_own_card(nc)
            if ok:
                consecutive_failures = 0
            else:
                raise RuntimeError("all card destinations rejected publish")
        except Exception as e:
            consecutive_failures += 1
            if consecutive_failures >= _CARD_REFRESH_WARN_AFTER:
                logger.warning(
                    "card_refresh_loop_error (failure %d): %s", consecutive_failures, e
                )
            else:
                logger.debug("card_refresh_loop_error: %s", e)


async def _healthcheck() -> str | None:
    """Verify NATS connectivity + KV bucket.

    Returns None on success, a string prefixed 'AUTH:' for non-retriable auth
    failures, or a plain string for transient connectivity errors.
    """
    _async_auth_err: list[Exception] = []

    async def _error_cb(e: Exception) -> None:
        if _is_auth_err(str(e)):
            _async_auth_err.append(e)

    try:
        nc = await nats_connect(
            NATS_URL,
            user_credentials=CREDS_PATH,
            connect_timeout=5,
            allow_reconnect=False,
            max_reconnect_attempts=1,
            error_cb=_error_cb,
        )
    except Exception as e:
        err_str = str(e).lower()
        if _is_auth_err(err_str):
            return f"AUTH:NATS auth rejected — check {CREDS_PATH} is valid for role '{ROLE}'"
        if any(w in err_str for w in _TRANSIENT_KEYWORDS):
            return f"Cannot reach NATS at {NATS_URL} — wrong URL or server down"
        return f"NATS connect failed: {e}"

    # Flush to surface async auth errors delivered after TCP connect.
    try:
        await asyncio.wait_for(nc.flush(timeout=2), timeout=2)
    except Exception:
        pass

    if _async_auth_err or nc.is_closed:
        try:
            await nc.close()
        except Exception:
            pass
        return f"AUTH:NATS auth rejected — check {CREDS_PATH} is valid for role '{ROLE}'"

    try:
        js = nc.jetstream()
        await js.key_value(KV_BUCKET)
    except Exception as e:
        await nc.close()
        err_str = str(e)
        if "bucket not found" in err_str.lower() or "BucketNotFound" in err_str:
            return (
                f"KV bucket '{KV_BUCKET}' not found on NATS server at {NATS_URL}. "
                f"Run 'aon bootstrap' or check AON_KV_BUCKET."
            )
        return f"KV error: {e}"

    # Verify we can actually publish (catches silent auth failures).
    try:
        await nc.publish(f"agents.{ROLE}.events", b'{"kind":"probe"}')
        await nc.flush(timeout=2)
    except Exception as e:
        await nc.close()
        return f"AUTH:Auth/publish test failed: {e}"

    await nc.close()
    return None


@asynccontextmanager
async def _lifespan(_server):
    """A2A worker accept-loop runs for the lifetime of the MCP server.

    Maya doesn't accept tasks (manager dispatches only), so skipped there.
    Runs connectivity healthcheck on startup with bounded retries for transient
    errors; exits immediately (sys.exit 1) on auth failure.
    """
    err: str | None = "not run"
    for attempt in range(3):
        err = await _healthcheck()
        if err is None:
            break
        if err.startswith("AUTH:"):
            raise RuntimeError(f"aon MCP startup failed: {err[5:]}")
        # Transient error — retry with backoff (2s, 4s).
        if attempt < 2:
            await asyncio.sleep(2 ** (attempt + 1))
    if err is not None:
        raise RuntimeError(f"aon MCP startup failed: {err}")

    nc = await client.nc()
    await _publish_own_card(nc)
    refresh_task = asyncio.create_task(_card_refresh_loop())

    accept_task = None
    if ROLE not in acl.MANAGER:
        accept_task = await start_accept_loop(client)
    try:
        yield {}
    finally:
        refresh_task.cancel()
        try:
            await refresh_task
        except (asyncio.CancelledError, Exception):
            pass
        if accept_task is not None:
            accept_task.cancel()
            try:
                await accept_task
            except (asyncio.CancelledError, Exception):
                pass


mcp = FastMCP("aon", lifespan=_lifespan)


# ── Helpers ─────────────────────────────────────────────────────────────

def _err(msg: str) -> dict[str, Any]:
    return {"ok": False, "error": msg, "role": ROLE}


def _ok(**fields: Any) -> dict[str, Any]:
    return {"ok": True, "role": ROLE, **fields}


# ── Role brief loader ──────────────────────────────────────────────────

@mcp.tool()
def get_role_brief() -> dict[str, Any]:
    """Return this role's brief (markdown). Call on first turn to load context.

    Combines the canonical substrate brief (templates/role-brief.md from the
    engine repo, with team values substituted) with the role-specific file
    from the team-aon repo (agent-prompts/<role>.md). Editing role-brief.md
    evolves common rules for all roles without re-rendering.
    """
    engine_dir = Path(os.environ.get("AON_ENGINE_DIR", os.path.expanduser("~/Repos/ai-over-nats")))
    kv_bucket = os.environ.get("AON_TEAM_KV", "")

    # Load canonical substrate from engine templates.
    substrate: str = ""
    brief_tmpl = engine_dir / "templates" / "role-brief.md"
    if brief_tmpl.is_file():
        substrate = brief_tmpl.read_text()
        substrate = substrate.replace("@TEAM_NAME@", TEAM).replace("@KV_BUCKET@", kv_bucket)

    # Load role-specific file from team repo.
    candidates: list[Path] = []
    team_toml = _find_team_toml(TEAM)
    team_repo = team_toml.parent if team_toml is not None else None
    if team_repo is not None and team_repo.is_dir():
        candidates.append(team_repo / "agent-prompts")
        candidates.append(team_repo / ".agent-prompts")

    role_md: str | None = None
    source: str | None = None
    for d in candidates:
        rp = d / f"{ROLE}.md"
        if rp.is_file():
            role_md = rp.read_text()
            source = str(rp)
            break

    if role_md is None:
        if substrate:
            return _ok(brief=substrate, source=str(brief_tmpl), team=TEAM,
                       warn=f"no role file for {ROLE} — checked: " + ", ".join(str(c) for c in candidates))
        return _err(
            f"no role brief found for {ROLE} — checked: "
            + ", ".join(str(c) for c in candidates)
        )

    body = (substrate + "\n\n---\n\n" + role_md) if substrate else role_md
    return _ok(brief=body, source=source, team=TEAM)


_NATS_OP_TIMEOUT = 3.0


@mcp.tool()
async def get_peer_cards() -> dict[str, Any]:
    """Return A2A agent cards for all team peers.

    Three-tier fallback per role:
    1. NATS KV agents.<role>.card  (updated on each agent boot)
    2. A2A_DISC stream last message (a2a.discovery.<role>)
       NOTE: Card 167 deliverable #2 specified request-reply; using get_last_msg()
       instead — simpler, equivalent for current intra-team use.
    3. agents/ git files (last resort)
    """
    from .a2a.cards import ALL_ROLES, all_cards, verify_card_acl_scope
    cards: dict[str, Any] = {}
    missing: list[str] = list(ALL_ROLES)
    _js = None

    # Tier 1: KV
    try:
        nc = await client.nc()
        _js = nc.jetstream()
        kv = await _js.key_value(KV_BUCKET)
        still_missing: list[str] = []
        for role in missing:
            try:
                entry = await asyncio.wait_for(
                    kv.get(f"agents.{role}.card"), timeout=_NATS_OP_TIMEOUT
                )
                if not verify_card_acl_scope(role, entry.key):
                    logger.warning(
                        "card_origin_mismatch role=%s key=%s bucket=%s — "
                        "expected agents.%s.card; ACL may have been bypassed",
                        role, entry.key, entry.bucket, role,
                    )
                cards[role] = json.loads(entry.value)
            except Exception:
                still_missing.append(role)
        missing = still_missing
    except Exception:
        pass

    # Tier 2: A2A_DISC stream (last message per subject)
    if missing:
        try:
            nc2 = await client.nc()
            js = _js if _js is not None else nc2.jetstream()
            still_missing: list[str] = []
            for role in missing:
                try:
                    msg = await asyncio.wait_for(
                        js.get_last_msg(_A2A_DISC_STREAM, subjects.a2a_discovery(role)),
                        timeout=_NATS_OP_TIMEOUT,
                    )
                    expected_subject = subjects.a2a_discovery(role)
                    if msg.subject != expected_subject:
                        logger.warning(
                            "card_origin_mismatch tier2 role=%s subject=%s — "
                            "expected %s; ACL may have been bypassed",
                            role, msg.subject, expected_subject,
                        )
                    cards[role] = json.loads(msg.data)
                except Exception:
                    still_missing.append(role)
            missing = still_missing
        except Exception:
            pass

    # Tier 3: git files
    # NOTE: ALL_ROLES is an import-time snapshot — roles added after startup won't appear here.
    if missing:
        git_cards = all_cards()
        for role in missing:
            if role in git_cards:
                cards[role] = git_cards[role]

    return _ok(cards=cards)


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
    allowed, why = acl.must_be_manager(ROLE)
    if not allowed:
        return _err(why)
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
    if peer not in ROSTER:
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
    if ROLE in acl.MANAGER:
        return _err(f"{ROLE} is manager-only; no inbox")
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
    if target_role not in ROSTER:
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

    Card lands at `$AON_BOARD_DIR/<slug>.md` (default
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
        os.environ.get("AON_BOARD_DIR", "~/.aon/board")
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

    import sys
    try:
        if args.transport == "stdio":
            mcp.run("stdio")
        else:
            # FastMCP HTTP transport (SSE-based).
            mcp.run("sse", port=args.port)
    except Exception as e:
        inners = getattr(e, "exceptions", [e])
        for inner in inners:
            msg = str(inner)
            if "aon MCP startup failed" in msg:
                print(f"[aon-mcp] {msg.replace('aon MCP startup failed: ', '')}", file=sys.stderr)
                sys.exit(1)
        raise


if __name__ == "__main__":
    main()
