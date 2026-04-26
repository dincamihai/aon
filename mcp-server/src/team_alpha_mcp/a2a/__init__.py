"""A2A protocol layer over NATS — slice 1.

Subject taxonomy:
    a2a.<role>.tasks.send                 request-reply, JSON-RPC-ish
    a2a.<role>.tasks.<task_id>.status     state updates
    a2a.<role>.tasks.<task_id>.message    streaming chunks (slice 2+)
    a2a.<role>.tasks.<task_id>.cancel     cancel signal (slice 2+)
    a2a.discovery.<role>                  card lookup (slice 2+ for NATS path)

Lifecycle states (A2A canonical, single vocabulary post-decision):
    submitted, working, input-required, completed, failed, canceled

Preemption (substrate `parked`) maps at the boundary to `input-required`
with reason="preempted". See lifecycle.py.
"""

from .cards import load_card, resolve_by_skill, ALL_ROLES
from .lifecycle import (
    STATES,
    transition,
    LifecycleError,
)
from .schemas import (
    validate_task_send,
    validate_status_update,
)
from .dispatcher import dispatch_task

__all__ = [
    "load_card",
    "resolve_by_skill",
    "ALL_ROLES",
    "STATES",
    "transition",
    "LifecycleError",
    "validate_task_send",
    "validate_status_update",
    "dispatch_task",
]
