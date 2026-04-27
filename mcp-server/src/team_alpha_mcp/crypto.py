"""HMAC envelope signing for tamper evidence on relayed messages.

Threat model: operators or relays modifying payloads after publish (e.g.,
JetStream history rewrite, malicious bouncer). NOT per-role identity proof
— shared cluster secret means any holder could forge. Asymmetric identity
proof (Ed25519) lands post-JWT migration in a follow-up slice.

Modes (env `TEAM_ALPHA_HMAC_MODE`):
  - "off" (default): no signing, no verification — current behavior.
  - "warn": sign on publish; verify on receive but pass unsigned (log only).
  - "strict": sign on publish; verify on receive; reject unsigned/invalid.

Key source (precedence):
  1. `TEAM_ALPHA_HMAC_KEY` env — raw key bytes/string.
  2. `TEAM_ALPHA_HMAC_KEY_FILE` env — file path (default
     `~/.team-alpha/cluster.hmac`, chmod 600).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import time
from collections import OrderedDict
from typing import Any

ENVELOPE_VERSION = 1
DEFAULT_REPLAY_WINDOW = 300  # seconds
REPLAY_CACHE_SIZE = 10_000


class CryptoError(Exception):
    """Base class for envelope verification failures."""


class SignatureError(CryptoError):
    """Signature missing, malformed, or does not match payload."""


class ReplayError(CryptoError):
    """Nonce seen within replay window."""


class StaleError(CryptoError):
    """Envelope timestamp outside accepted window."""


class ConfigError(CryptoError):
    """Mode or key configuration invalid."""


def get_mode() -> str:
    mode = os.environ.get("TEAM_ALPHA_HMAC_MODE", "off").strip().lower()
    if mode not in ("off", "warn", "strict"):
        raise ConfigError(
            f"TEAM_ALPHA_HMAC_MODE must be off/warn/strict; got {mode!r}"
        )
    return mode


def _load_key() -> bytes:
    raw = os.environ.get("TEAM_ALPHA_HMAC_KEY")
    if raw:
        return raw.encode() if isinstance(raw, str) else raw
    path = os.path.expanduser(
        os.environ.get("TEAM_ALPHA_HMAC_KEY_FILE", "~/.team-alpha/cluster.hmac")
    )
    if not os.path.isfile(path):
        raise ConfigError(f"HMAC key file not found: {path}")
    with open(path, "rb") as f:
        data = f.read().strip()
    if not data:
        raise ConfigError(f"HMAC key file empty: {path}")
    return data


_KEY_CACHE: bytes | None = None


def _key() -> bytes:
    global _KEY_CACHE
    if _KEY_CACHE is None:
        _KEY_CACHE = _load_key()
    return _KEY_CACHE


def _reset_key_cache() -> None:
    """Test hook: force re-read of key on next sign/verify."""
    global _KEY_CACHE
    _KEY_CACHE = None


def _canonical(obj: Any) -> bytes:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()


def _compute_sig(by: str, ts: int, nonce: str, payload: dict[str, Any]) -> str:
    msg = _canonical({"v": ENVELOPE_VERSION, "by": by, "ts": ts,
                      "nonce": nonce, "payload": payload})
    return hmac.new(_key(), msg, hashlib.sha256).hexdigest()


def sign_envelope(payload: dict[str, Any], role: str) -> dict[str, Any]:
    """Wrap `payload` in a signed envelope. `role` is bound into the signature
    so swapping `by` later invalidates the sig."""
    if not isinstance(payload, dict):
        raise TypeError("payload must be dict")
    if not role:
        raise ValueError("role required")
    ts = int(time.time())
    nonce = secrets.token_hex(8)
    sig = _compute_sig(role, ts, nonce, payload)
    return {
        "v": ENVELOPE_VERSION,
        "by": role,
        "ts": ts,
        "nonce": nonce,
        "payload": payload,
        "sig": sig,
    }


class _ReplayCache:
    """LRU-bounded nonce cache. Per-process; survives until restart.

    Nonce + ts pair tracked; eviction by capacity. For multi-process or
    cross-restart deduplication, persist to KV in a follow-up slice.
    """

    def __init__(self, capacity: int = REPLAY_CACHE_SIZE) -> None:
        self.capacity = capacity
        self._seen: OrderedDict[str, int] = OrderedDict()

    def check_and_add(self, nonce: str, ts: int) -> bool:
        """Return True if novel (added). False if replay."""
        if nonce in self._seen:
            return False
        self._seen[nonce] = ts
        if len(self._seen) > self.capacity:
            self._seen.popitem(last=False)
        return True

    def clear(self) -> None:
        self._seen.clear()


_REPLAY_CACHE = _ReplayCache()


_REQUIRED_FIELDS = ("v", "by", "ts", "nonce", "payload", "sig")
_TYPE_CHECKS: tuple[tuple[str, type, str], ...] = (
    ("ts", int, "ts must be int"),
    ("payload", dict, "payload must be dict"),
)


def _validate_envelope_shape(env: dict[str, Any]) -> None:
    if not isinstance(env, dict):
        raise SignatureError("envelope must be dict")
    for k in _REQUIRED_FIELDS:
        if k not in env:
            raise SignatureError(f"missing field: {k}")
    if env["v"] != ENVELOPE_VERSION:
        raise SignatureError(f"unsupported envelope version: {env['v']}")
    for field, expected_type, msg in _TYPE_CHECKS:
        if not isinstance(env[field], expected_type):
            raise SignatureError(msg)
    if not isinstance(env["by"], str) or not env["by"]:
        raise SignatureError("by must be non-empty string")


def verify_envelope(
    env: dict[str, Any],
    *,
    expected_role: str | None = None,
    replay_window: int = DEFAULT_REPLAY_WINDOW,
    now: int | None = None,
    cache: _ReplayCache | None = None,
) -> dict[str, Any]:
    """Verify signed envelope. Returns inner payload dict.

    Raises:
      SignatureError — missing/malformed/mismatched signature, role mismatch.
      ReplayError    — nonce already seen.
      StaleError     — ts outside replay_window.
    """
    _validate_envelope_shape(env)
    by, ts, nonce, payload, sig = (
        env["by"], env["ts"], env["nonce"], env["payload"], env["sig"]
    )
    if expected_role is not None and by != expected_role:
        raise SignatureError(
            f"role mismatch: envelope by={by!r} expected={expected_role!r}"
        )
    if not hmac.compare_digest(_compute_sig(by, ts, nonce, payload), sig):
        raise SignatureError("signature mismatch")
    cur = now if now is not None else int(time.time())
    if abs(cur - ts) > replay_window:
        raise StaleError(
            f"ts {ts} outside replay window ±{replay_window}s of {cur}"
        )
    rc = cache if cache is not None else _REPLAY_CACHE
    if not rc.check_and_add(nonce, ts):
        raise ReplayError(f"nonce {nonce!r} already seen")
    return payload


def is_envelope(obj: Any) -> bool:
    """Cheap shape check for incoming-message routing."""
    return (
        isinstance(obj, dict)
        and obj.get("v") == ENVELOPE_VERSION
        and "sig" in obj
        and "payload" in obj
    )


# ── Convenience wrappers for non-event_payload publish/receive paths ────────

def wrap_payload(body: dict[str, Any], role: str) -> bytes:
    """Mode-aware: serialize raw JSON when off, signed envelope when warn/strict."""
    import json as _json
    if get_mode() == "off":
        return _json.dumps(body, separators=(",", ":")).encode()
    env = sign_envelope(body, role)
    return _json.dumps(env, separators=(",", ":")).encode()


def unwrap_payload(
    raw: bytes, *, expected_role: str | None = None
) -> dict[str, Any]:
    """Decode raw bytes per current mode. Returns inner payload dict.

    Modes:
      - off:    parse JSON; return as-is. Envelope-shaped messages returned
                as the envelope dict (caller likely wants `.payload` then).
      - warn:   if signed, verify; if invalid, raise. If unsigned, log warn
                and return parsed JSON (legacy compat during rollout).
      - strict: must be signed envelope and verify. Unsigned/bad → raise.

    Raises:
      SignatureError / ReplayError / StaleError as appropriate.
      ValueError on JSON decode failure.
    """
    import json as _json
    try:
        obj = _json.loads(raw.decode()) if raw else {}
    except Exception as e:
        raise ValueError(f"json decode: {e}") from e
    if not isinstance(obj, dict):
        raise ValueError("payload must be json object")
    return unwrap_dict(obj, expected_role=expected_role)


def unwrap_dict(
    obj: dict[str, Any], *, expected_role: str | None = None
) -> dict[str, Any]:
    """Same as unwrap_payload but for already-parsed dicts (e.g. from
    recent_events replay). Mode-aware verification.
    """
    mode = get_mode()
    if mode == "off":
        # If a signed envelope happens to be in flight, surface its payload
        # so callers stay agnostic. Don't verify in off mode.
        return obj["payload"] if is_envelope(obj) and isinstance(obj.get("payload"), dict) else obj
    if is_envelope(obj):
        return verify_envelope(obj, expected_role=expected_role)
    # Unsigned in non-off mode
    if mode == "strict":
        raise SignatureError("unsigned message rejected in strict mode")
    # warn: log and pass through legacy
    import logging as _logging
    _logging.getLogger(__name__).warning(
        "unsigned message accepted (mode=warn); upgrade publishers"
    )
    return obj
