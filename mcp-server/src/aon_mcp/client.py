"""NATS connection + KV + AUDIT replay helpers.

One process = one role. Lazy reconnect on close. Hides ephemeral consumer
mgmt + replay-window tuning behind a typed surface.
"""
from __future__ import annotations

import asyncio
import json
import os
import secrets
import time
from datetime import datetime, timezone
from typing import Any, AsyncIterator

import nats
from nats.aio.client import Client as NATS
from nats.js import JetStreamContext
from nats.js.api import (
    ConsumerConfig,
    DeliverPolicy,
    AckPolicy,
    ReplayPolicy,
)
from nats.js.kv import KeyValue

# ── Defaults baked in (per "per-action params" in card 110) ──────────────
COUNT_CAP   = 500
WAIT_REPLAY = 1.0   # seconds — single fetch attempt
WAIT_LIVE   = 5.0
INACTIVE_GC = 10    # seconds — auto-clean leaked ephemerals
KV_BUCKET   = os.environ.get("AON_KV_BUCKET", "team-state")
AUDIT_STREAM = "AUDIT"

# Card 95: bounded infra retry. ANY infrastructure transient retry MUST stay
# under this ceiling. Semantic waits (peer not replied, human busy) NEVER
# retry — they go through ASK chain at the agent layer.
MAX_RETRY_BUDGET_SEC = 5.0

# Card 95: per-peer DM flood guard. Refuse N+1th message to same peer within
# WINDOW seconds. Resets on receipt of a reply (caller informs).
DM_FLOOD_LIMIT  = 5
DM_FLOOD_WINDOW = 60.0  # seconds


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def consumer_name(prefix: str = "mcp") -> str:
    return f"{prefix}-{os.getpid()}-{time.monotonic_ns()}-{secrets.token_hex(2)}"


def event_payload(role: str, slug: str, **extra: Any) -> bytes:
    """Canonical event payload. Tools build on this; field names stable."""
    body = {"slug": slug, "by": role, "ts": now_iso(), **extra}
    return json.dumps(body, separators=(",", ":")).encode()


class TeamAlphaClient:
    """Single per-process NATS client tied to one role."""

    def __init__(self, role: str, nats_url: str, password: str) -> None:
        self.role = role
        self.nats_url = nats_url
        self.password = password
        self._nc: NATS | None = None
        self._js: JetStreamContext | None = None
        self._kv: KeyValue | None = None
        self._lock = asyncio.Lock()
        # Card 95 flood guard: per-peer rolling timestamps of recent DMs.
        self._dm_log: dict[str, list[float]] = {}

    def dm_check_flood(self, peer: str) -> tuple[bool, str]:
        """Pre-DM gate. Returns (allowed, reason). Caller invokes before
        publishing. Maintains rolling window per peer; resets via dm_mark_reply."""
        now = time.time()
        log = self._dm_log.setdefault(peer, [])
        log[:] = [t for t in log if now - t < DM_FLOOD_WINDOW]
        if len(log) >= DM_FLOOD_LIMIT:
            return False, (
                f"flood guard: {len(log)} DMs to '{peer}' in last "
                f"{DM_FLOOD_WINDOW:.0f}s ≥ {DM_FLOOD_LIMIT} cap. "
                f"Stop messaging this peer; escalate via ASK chain instead."
            )
        log.append(now)
        return True, ""

    def dm_mark_reply(self, peer: str) -> None:
        """Caller invokes when peer replies — clears flood window for that peer."""
        self._dm_log.pop(peer, None)

    async def _connect(self) -> NATS:
        nc = await nats.connect(
            self.nats_url,
            user=self.role,
            password=self.password,
            allow_reconnect=True,
            max_reconnect_attempts=-1,
            reconnect_time_wait=2,
            connect_timeout=5,
        )
        return nc

    async def nc(self) -> NATS:
        if self._nc is None or self._nc.is_closed:
            async with self._lock:
                if self._nc is None or self._nc.is_closed:
                    self._nc = await self._connect()
                    self._js = self._nc.jetstream()
                    self._kv = await self._js.key_value(KV_BUCKET)
        return self._nc  # type: ignore[return-value]

    async def js(self) -> JetStreamContext:
        await self.nc()
        return self._js  # type: ignore[return-value]

    async def kv(self) -> KeyValue:
        await self.nc()
        return self._kv  # type: ignore[return-value]

    # ── Publish ─────────────────────────────────────────────────────────
    async def publish(self, subject: str, payload: bytes) -> None:
        nc = await self.nc()
        await nc.publish(subject, payload)
        await nc.flush(timeout=2)

    async def request_reply(
        self, subject: str, payload: bytes, timeout: float = WAIT_LIVE
    ) -> dict[str, Any] | None:
        nc = await self.nc()
        try:
            msg = await nc.request(subject, payload, timeout=timeout)
            return json.loads(msg.data.decode()) if msg.data else None
        except Exception:
            return None

    # ── KV ───────────────────────────────────────────────────────────────
    async def kv_put(self, key: str, value: Any) -> int:
        kv = await self.kv()
        body = value if isinstance(value, (bytes, str)) else json.dumps(value, separators=(",", ":"))
        if isinstance(body, str):
            body = body.encode()
        rev = await kv.put(key, body)
        return int(rev)

    async def kv_get(self, key: str) -> dict[str, Any] | None:
        kv = await self.kv()
        try:
            entry = await kv.get(key)
        except Exception:
            return None
        if entry is None or entry.value is None:
            return None
        try:
            return json.loads(entry.value.decode())
        except Exception:
            return {"raw": entry.value.decode(errors="replace")}

    # ── AUDIT replay (the foot-gun helper) ──────────────────────────────
    async def recent_events(
        self,
        subject: str,
        since: str = "60s",
        limit: int = COUNT_CAP,
        slug_filter: str | None = None,
    ) -> list[dict[str, Any]]:
        """Replay AUDIT for `subject` with bounded `since` window.

        Always uses ephemeral pull consumer; auto-cleanup; never leaks.
        Caller need not know about consumer flags or stream layout.
        """
        js = await self.js()
        cname = consumer_name("mcp-replay")
        cfg = ConsumerConfig(
            durable_name=None,
            filter_subject=subject,
            deliver_policy=DeliverPolicy.BY_START_TIME,
            opt_start_time=_since_to_rfc3339(since),
            ack_policy=AckPolicy.NONE,
            replay_policy=ReplayPolicy.INSTANT,
            inactive_threshold=INACTIVE_GC,  # nats-py: float seconds, not ns
        )
        try:
            await js.add_consumer(stream=AUDIT_STREAM, config=cfg, name=cname)
        except Exception:
            return []

        sub = await js.pull_subscribe_bind(consumer=cname, stream=AUDIT_STREAM)
        out: list[dict[str, Any]] = []
        # Retry to absorb AUDIT-mirror lag without forcing the caller to know
        # how long it takes (sources from EVENTS/TASKS are async). 3 tries,
        # back-off 0.4s → 1.2s → 2.4s ≈ 4s upper bound, transparent to caller.
        attempts = [0.4, 1.2, 2.4]
        try:
            for delay in attempts:
                try:
                    msgs = await sub.fetch(batch=min(limit, COUNT_CAP), timeout=WAIT_REPLAY)
                except Exception:
                    msgs = []
                for m in msgs:
                    try:
                        body = json.loads(m.data.decode())
                    except Exception:
                        continue
                    if slug_filter and body.get("slug") != slug_filter:
                        continue
                    out.append(body)
                    if len(out) >= limit:
                        break
                if out or not slug_filter:
                    # If filtering for a specific slug and not yet found, keep
                    # waiting. Otherwise (broad query) first batch is enough.
                    if not slug_filter or out:
                        break
                await asyncio.sleep(delay)
        finally:
            try:
                await js.delete_consumer(stream=AUDIT_STREAM, consumer=cname)
            except Exception:
                pass
        return out


def _since_to_rfc3339(since: str) -> str:
    """Parse '60s' / '5m' / '2h' into an RFC3339 string with microseconds + Z.

    nats-py ConsumerConfig.opt_start_time is serialized as JSON string; the
    JetStream server parses it strictly — bare-second precision fails. Use
    microsecond precision + 'Z' suffix (UTC).
    """
    s = since.strip().lower()
    n = int("".join(c for c in s if c.isdigit()) or "60")
    unit = s[-1] if s and s[-1].isalpha() else "s"
    secs = {"s": 1, "m": 60, "h": 3600, "d": 86400}.get(unit, 1) * n
    dt = datetime.fromtimestamp(time.time() - secs, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
