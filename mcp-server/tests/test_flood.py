"""Card 95 — flood guard unit tests (no NATS needed)."""
from aon_mcp.client import (
    TeamAlphaClient, DM_FLOOD_LIMIT, DM_FLOOD_WINDOW,
)


def _client():
    # Flood-guard tests never touch NATS; pass a dummy creds path.
    return TeamAlphaClient("lin", "nats://x:4222", "/dev/null")


def test_first_dm_allowed():
    c = _client()
    ok, _ = c.dm_check_flood("raj")
    assert ok


def test_under_limit_all_allowed():
    c = _client()
    for i in range(DM_FLOOD_LIMIT):
        ok, why = c.dm_check_flood("raj")
        assert ok, (i, why)


def test_over_limit_refused():
    c = _client()
    for _ in range(DM_FLOOD_LIMIT):
        c.dm_check_flood("raj")
    ok, why = c.dm_check_flood("raj")
    assert not ok
    assert "flood guard" in why
    assert "raj" in why


def test_different_peers_independent():
    c = _client()
    for _ in range(DM_FLOOD_LIMIT):
        c.dm_check_flood("raj")
    # Other peers still under their own limit.
    for peer in ("maya", "diego", "sam"):
        ok, _ = c.dm_check_flood(peer)
        assert ok, peer


def test_reply_resets_window():
    c = _client()
    for _ in range(DM_FLOOD_LIMIT):
        c.dm_check_flood("raj")
    ok, _ = c.dm_check_flood("raj")
    assert not ok
    c.dm_mark_reply("raj")
    ok, _ = c.dm_check_flood("raj")
    assert ok, "post-reply DM should be allowed again"


def test_window_settings_sane():
    # Sanity bounds — if these change, check tests above still meaningful.
    assert 1 <= DM_FLOOD_LIMIT <= 20
    assert 10.0 <= DM_FLOOD_WINDOW <= 600.0
