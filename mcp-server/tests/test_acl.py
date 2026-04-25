"""Pure unit tests for ACL tables — no NATS required."""
from team_alpha_mcp import acl


def test_maya_cannot_claim():
    ok, why = acl.can_claim_task("maya", "terraform")
    assert not ok
    assert "cannot claim" in why


def test_raj_can_claim_anywhere():
    for d in ("python", "ui", "go", "terraform", "aws"):
        ok, _ = acl.can_claim_task("raj", d)
        assert ok, d


def test_sam_blocked_on_production_python():
    ok, why = acl.can_claim_task("sam", "python")
    assert not ok
    assert "ui" in why  # error message lists allowed domains


def test_sam_can_learn_python():
    ok, _ = acl.can_claim_learning("sam", "python")
    assert ok


def test_sam_cannot_learn_terraform():
    # Sam's growth list is python+go, not infra
    ok, _ = acl.can_claim_learning("sam", "terraform")
    assert not ok


def test_lin_can_claim_go_production():
    # Lin is mid generalist with go in growth — but production go IS allowed
    # (per MODEL.md: she should pair, but ACL permits).
    ok, _ = acl.can_claim_task("lin", "go")
    assert ok


def test_priya_blocked_python_production():
    ok, why = acl.can_claim_task("priya", "python")
    assert not ok


def test_priya_can_learn_python():
    ok, _ = acl.can_claim_learning("priya", "python")
    assert ok


def test_only_maya_can_post_tasks():
    for r in ("raj", "lin", "sam", "diego", "priya"):
        ok, _ = acl.can_post_task(r)
        assert not ok, r
    ok, _ = acl.can_post_task("maya")
    assert ok


def test_maya_cannot_post_results():
    # Manager doesn't ship — doers do.
    ok, _ = acl.can_post_results("maya", "terraform")
    assert not ok


def test_only_raj_offers_mentoring():
    ok, _ = acl.can_offer_mentoring("raj", "go")
    assert ok
    for r in ("lin", "sam", "diego", "priya", "maya"):
        ok, _ = acl.can_offer_mentoring(r, "go")
        assert not ok, r
