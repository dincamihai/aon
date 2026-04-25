"""Integration smoke against a running team-alpha substrate.

Requires:
  TEAM_ALPHA_ROLE / TEAM_ALPHA_NATS_URL / TEAM_ALPHA_CREDS set
  NATS reachable + bootstrapped (TASKS, AUDIT, KV team-state present)

Run:
  TEAM_ALPHA_ROLE=lin TEAM_ALPHA_NATS_URL=nats://localhost:4222 \
    TEAM_ALPHA_CREDS=/tmp/lin.pw \
    python -m pytest tests/test_smoke.py -v
"""
import asyncio
import os
import time

import pytest


pytestmark = pytest.mark.skipif(
    not os.environ.get("TEAM_ALPHA_ROLE"),
    reason="env not set; smoke test requires running substrate",
)


@pytest.fixture
def client():
    from team_alpha_mcp.client import TeamAlphaClient
    role = os.environ["TEAM_ALPHA_ROLE"]
    url  = os.environ["TEAM_ALPHA_NATS_URL"]
    pw   = open(os.path.expanduser(os.environ["TEAM_ALPHA_CREDS"])).read().strip()
    return TeamAlphaClient(role, url, pw)


def test_connect(client):
    async def go():
        nc = await client.nc()
        assert nc.is_connected
        await nc.close()
    asyncio.run(go())


def test_kv_roundtrip(client):
    async def go():
        from team_alpha_mcp.subjects import kv_agent_load
        from team_alpha_mcp.client import now_iso
        role = client.role
        body = {"capacity": "active", "current_tasks": 0, "since": now_iso(),
                "marker": f"smoke-{time.time()}"}
        rev = await client.kv_put(kv_agent_load(role), body)
        assert rev > 0
        got = await client.kv_get(kv_agent_load(role))
        assert got is not None
        assert got.get("marker") == body["marker"]
        nc = await client.nc()
        await nc.close()
    asyncio.run(go())


def test_publish_to_own_events(client):
    async def go():
        from team_alpha_mcp.subjects import agent_events
        from team_alpha_mcp.client import event_payload
        role = client.role
        await client.publish(
            agent_events(role),
            event_payload(role, slug="smoke-test", type="ping"),
        )
        nc = await client.nc()
        await nc.close()
    asyncio.run(go())


def test_recent_events_works(client):
    async def go():
        from team_alpha_mcp.subjects import agent_events
        from team_alpha_mcp.client import event_payload
        role = client.role
        slug = f"smoke-{int(time.time()*1000)}"
        await client.publish(
            agent_events(role),
            event_payload(role, slug=slug, type="recent_test"),
        )
        # No tunable sleep — client.recent_events handles AUDIT mirror lag
        # internally (3 retries with back-off). Test is robust to env timing.
        events = await client.recent_events(
            subject=agent_events(role), since="30s", slug_filter=slug,
        )
        assert any(e.get("slug") == slug for e in events), \
            f"no event with slug={slug} in {events!r}"
        nc = await client.nc()
        await nc.close()
    asyncio.run(go())
