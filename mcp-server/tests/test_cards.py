"""Pure unit tests for card helpers — no NATS required."""
from aon_mcp.a2a.cards import verify_card_acl_scope


def test_correct_key_returns_true():
    assert verify_card_acl_scope("maya", "agents.maya.card") is True


def test_wrong_role_returns_false():
    assert verify_card_acl_scope("maya", "agents.raj.card") is False


def test_path_traversal_returns_false():
    assert verify_card_acl_scope("maya", "agents/../maya.card") is False
    assert verify_card_acl_scope("maya", "agents.maya.card.extra") is False


def test_empty_key_returns_false():
    assert verify_card_acl_scope("maya", "") is False
