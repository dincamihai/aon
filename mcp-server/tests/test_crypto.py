"""HMAC envelope signing tests. Pure unit — no NATS, no IO beyond env."""
from __future__ import annotations

import json
import os
import time

import pytest

from team_alpha_mcp import crypto


@pytest.fixture(autouse=True)
def _hmac_env(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_KEY", "test-cluster-secret-DO-NOT-USE")
    monkeypatch.delenv("TEAM_ALPHA_HMAC_KEY_FILE", raising=False)
    crypto._reset_key_cache()
    yield
    crypto._reset_key_cache()


@pytest.fixture
def fresh_cache():
    return crypto._ReplayCache(capacity=64)


# ── roundtrip ──────────────────────────────────────────────────────────────

def test_sign_verify_roundtrip(fresh_cache):
    payload = {"slug": "t1", "by": "lin", "ts": "2026-04-27T10:00:00Z", "x": 1}
    env = crypto.sign_envelope(payload, "lin")
    out = crypto.verify_envelope(env, expected_role="lin", cache=fresh_cache)
    assert out == payload


def test_envelope_shape(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    assert env["v"] == 1
    assert env["by"] == "raj"
    assert isinstance(env["ts"], int)
    assert len(env["nonce"]) == 16  # 8 bytes hex
    assert env["payload"] == {"a": 1}
    assert len(env["sig"]) == 64  # sha256 hex


def test_is_envelope_predicate():
    env = crypto.sign_envelope({"a": 1}, "raj")
    assert crypto.is_envelope(env)
    assert not crypto.is_envelope({"slug": "raw", "by": "raj"})
    assert not crypto.is_envelope("string")
    assert not crypto.is_envelope(None)


# ── tamper detection ──────────────────────────────────────────────────────

def test_tamper_payload_field(fresh_cache):
    env = crypto.sign_envelope({"amount": 10}, "raj")
    env["payload"]["amount"] = 9999
    with pytest.raises(crypto.SignatureError, match="signature mismatch"):
        crypto.verify_envelope(env, cache=fresh_cache)


def test_tamper_by_field(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    env["by"] = "lin"
    with pytest.raises(crypto.SignatureError):
        crypto.verify_envelope(env, cache=fresh_cache)


def test_tamper_ts(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    env["ts"] = env["ts"] + 1
    with pytest.raises(crypto.SignatureError, match="signature mismatch"):
        crypto.verify_envelope(env, cache=fresh_cache)


def test_tamper_sig_truncated(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    last = env["sig"][-1]
    flipped = "f" if last != "f" else "0"
    env["sig"] = env["sig"][:-1] + flipped
    with pytest.raises(crypto.SignatureError):
        crypto.verify_envelope(env, cache=fresh_cache)


def test_role_mismatch(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    with pytest.raises(crypto.SignatureError, match="role mismatch"):
        crypto.verify_envelope(env, expected_role="lin", cache=fresh_cache)


def test_missing_field(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    del env["nonce"]
    with pytest.raises(crypto.SignatureError, match="missing field: nonce"):
        crypto.verify_envelope(env, cache=fresh_cache)


def test_unsupported_version(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    env["v"] = 99
    with pytest.raises(crypto.SignatureError, match="unsupported envelope version"):
        crypto.verify_envelope(env, cache=fresh_cache)


# ── replay ────────────────────────────────────────────────────────────────

def test_replay_same_nonce(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    crypto.verify_envelope(env, cache=fresh_cache)
    with pytest.raises(crypto.ReplayError):
        crypto.verify_envelope(env, cache=fresh_cache)


def test_independent_nonces_pass(fresh_cache):
    for _ in range(5):
        env = crypto.sign_envelope({"a": 1}, "raj")
        crypto.verify_envelope(env, cache=fresh_cache)


def test_replay_cache_eviction():
    cache = crypto._ReplayCache(capacity=3)
    cache.check_and_add("n1", 0)
    cache.check_and_add("n2", 0)
    cache.check_and_add("n3", 0)
    # n4 evicts n1
    cache.check_and_add("n4", 0)
    assert cache.check_and_add("n1", 0) is True  # evicted, re-add allowed
    assert cache.check_and_add("n4", 0) is False  # still cached


# ── staleness ─────────────────────────────────────────────────────────────

def test_stale_ts_rejected(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    fake_now = env["ts"] + 1000
    with pytest.raises(crypto.StaleError):
        crypto.verify_envelope(env, replay_window=300, now=fake_now,
                               cache=fresh_cache)


def test_future_ts_rejected(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    fake_now = env["ts"] - 1000
    with pytest.raises(crypto.StaleError):
        crypto.verify_envelope(env, replay_window=300, now=fake_now,
                               cache=fresh_cache)


def test_within_window_passes(fresh_cache):
    env = crypto.sign_envelope({"a": 1}, "raj")
    crypto.verify_envelope(env, replay_window=300, now=env["ts"] + 200,
                           cache=fresh_cache)


# ── modes ─────────────────────────────────────────────────────────────────

def test_mode_default_off(monkeypatch):
    monkeypatch.delenv("TEAM_ALPHA_HMAC_MODE", raising=False)
    assert crypto.get_mode() == "off"


def test_mode_warn(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "warn")
    assert crypto.get_mode() == "warn"


def test_mode_strict(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "strict")
    assert crypto.get_mode() == "strict"


def test_mode_invalid(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "loose")
    with pytest.raises(crypto.ConfigError):
        crypto.get_mode()


# ── key sources ───────────────────────────────────────────────────────────

def test_key_from_file(tmp_path, monkeypatch):
    keyfile = tmp_path / "cluster.hmac"
    keyfile.write_bytes(b"file-loaded-secret\n")
    monkeypatch.delenv("TEAM_ALPHA_HMAC_KEY", raising=False)
    monkeypatch.setenv("TEAM_ALPHA_HMAC_KEY_FILE", str(keyfile))
    crypto._reset_key_cache()
    env = crypto.sign_envelope({"a": 1}, "raj")
    crypto.verify_envelope(env, cache=crypto._ReplayCache())


def test_key_file_missing(tmp_path, monkeypatch):
    monkeypatch.delenv("TEAM_ALPHA_HMAC_KEY", raising=False)
    monkeypatch.setenv("TEAM_ALPHA_HMAC_KEY_FILE",
                       str(tmp_path / "absent.hmac"))
    crypto._reset_key_cache()
    with pytest.raises(crypto.ConfigError, match="not found"):
        crypto.sign_envelope({"a": 1}, "raj")


def test_key_file_empty(tmp_path, monkeypatch):
    keyfile = tmp_path / "cluster.hmac"
    keyfile.write_text("   \n")
    monkeypatch.delenv("TEAM_ALPHA_HMAC_KEY", raising=False)
    monkeypatch.setenv("TEAM_ALPHA_HMAC_KEY_FILE", str(keyfile))
    crypto._reset_key_cache()
    with pytest.raises(crypto.ConfigError, match="empty"):
        crypto.sign_envelope({"a": 1}, "raj")


def test_different_keys_dont_verify(tmp_path, monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_KEY", "key-A")
    crypto._reset_key_cache()
    env = crypto.sign_envelope({"a": 1}, "raj")
    monkeypatch.setenv("TEAM_ALPHA_HMAC_KEY", "key-B")
    crypto._reset_key_cache()
    with pytest.raises(crypto.SignatureError):
        crypto.verify_envelope(env, cache=crypto._ReplayCache())


# ── perf sanity ───────────────────────────────────────────────────────────

def test_perf_sign_verify_under_1ms():
    payload = {"task_id": "t1", "summary": "x" * 800, "by": "raj"}
    cache = crypto._ReplayCache()
    start = time.perf_counter()
    iters = 200
    for _ in range(iters):
        env = crypto.sign_envelope(payload, "raj")
        crypto.verify_envelope(env, cache=cache)
    elapsed = time.perf_counter() - start
    per_op = elapsed / iters
    assert per_op < 0.001, f"too slow: {per_op*1000:.3f}ms per sign+verify"


# ── event_payload integration ─────────────────────────────────────────────

def test_event_payload_off_by_default(monkeypatch):
    monkeypatch.delenv("TEAM_ALPHA_HMAC_MODE", raising=False)
    from team_alpha_mcp.client import event_payload
    raw = event_payload("raj", "slug-1", x=1)
    body = json.loads(raw)
    assert body == {"slug": "slug-1", "by": "raj", "ts": body["ts"], "x": 1}
    assert "sig" not in body


def test_wrap_payload_off(monkeypatch):
    monkeypatch.delenv("TEAM_ALPHA_HMAC_MODE", raising=False)
    raw = crypto.wrap_payload({"a": 1}, "raj")
    body = json.loads(raw)
    assert body == {"a": 1}


def test_wrap_unwrap_strict_roundtrip(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "strict")
    crypto._reset_key_cache()
    raw = crypto.wrap_payload({"task_id": "t1", "state": "working"}, "raj")
    inner = crypto.unwrap_payload(raw, expected_role="raj")
    assert inner["task_id"] == "t1"
    assert inner["state"] == "working"


def test_unwrap_strict_rejects_unsigned(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "strict")
    crypto._reset_key_cache()
    raw = json.dumps({"task_id": "t1"}).encode()
    with pytest.raises(crypto.SignatureError, match="strict"):
        crypto.unwrap_payload(raw)


def test_unwrap_warn_accepts_unsigned(monkeypatch, caplog):
    import logging
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "warn")
    crypto._reset_key_cache()
    raw = json.dumps({"task_id": "t1"}).encode()
    with caplog.at_level(logging.WARNING):
        body = crypto.unwrap_payload(raw)
    assert body == {"task_id": "t1"}
    assert any("unsigned" in r.message for r in caplog.records)


def test_unwrap_off_passes_envelope_payload(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "strict")
    crypto._reset_key_cache()
    raw = crypto.wrap_payload({"task_id": "t1"}, "raj")
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "off")
    body = crypto.unwrap_payload(raw)
    # in off mode envelope.payload surfaces transparently
    assert body == {"task_id": "t1"}


def test_unwrap_off_passes_raw(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "off")
    raw = json.dumps({"task_id": "t1"}).encode()
    assert crypto.unwrap_payload(raw) == {"task_id": "t1"}


def test_event_payload_strict_signs(monkeypatch):
    monkeypatch.setenv("TEAM_ALPHA_HMAC_MODE", "strict")
    crypto._reset_key_cache()
    from team_alpha_mcp.client import event_payload
    raw = event_payload("raj", "slug-1", x=1)
    env = json.loads(raw)
    assert crypto.is_envelope(env)
    inner = crypto.verify_envelope(env, expected_role="raj",
                                   cache=crypto._ReplayCache())
    assert inner["slug"] == "slug-1"
    assert inner["x"] == 1
