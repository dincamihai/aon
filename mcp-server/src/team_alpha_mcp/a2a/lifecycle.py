"""A2A lifecycle state machine — A2A canonical vocabulary only.

States (drift resolution #2, slice 1 §4):
    submitted, working, input-required, completed, failed, canceled

Substrate `parked` (preemption) folds into `input-required` with
`reason: "preempted"` at the boundary — never a distinct A2A state.
"""
from __future__ import annotations

STATES = (
    "submitted",
    "working",
    "input-required",
    "completed",
    "failed",
    "canceled",
)

TERMINAL = frozenset({"completed", "failed", "canceled"})

# Allowed transitions. Tight by design; widen with explicit reason in
# slice 2 if real flows demand.
_ALLOWED: dict[str, frozenset[str]] = {
    "submitted":      frozenset({"working", "canceled", "failed"}),
    "working":        frozenset({"input-required", "completed", "failed", "canceled"}),
    "input-required": frozenset({"working", "failed", "canceled"}),
    "completed":      frozenset(),
    "failed":         frozenset(),
    "canceled":       frozenset(),
}


class LifecycleError(ValueError):
    pass


def transition(from_state: str, to_state: str) -> None:
    """Raise LifecycleError if (from → to) is not allowed."""
    if from_state not in STATES:
        raise LifecycleError(f"unknown from-state: {from_state!r}")
    if to_state not in STATES:
        raise LifecycleError(f"unknown to-state: {to_state!r}")
    if to_state not in _ALLOWED[from_state]:
        raise LifecycleError(
            f"illegal transition {from_state!r} → {to_state!r}; "
            f"allowed: {sorted(_ALLOWED[from_state]) or '(terminal)'}"
        )


def is_terminal(state: str) -> bool:
    return state in TERMINAL


def map_substrate(substrate_state: str) -> tuple[str, str | None]:
    """Map substrate state name to (A2A state, optional reason).

    Substrate (board.tasks.<d>.<state>) → A2A canonical:
        pending  → submitted, None
        claimed  → working, None
        progress → working, None
        blocked  → input-required, "blocked"
        parked   → input-required, "preempted"
        resumed  → working, "resumed"
        done     → completed, None
        failed   → failed, None
        canceled → canceled, None
    """
    table: dict[str, tuple[str, str | None]] = {
        "pending":  ("submitted", None),
        "claimed":  ("working", None),
        "progress": ("working", None),
        "blocked":  ("input-required", "blocked"),
        "parked":   ("input-required", "preempted"),
        "resumed":  ("working", "resumed"),
        "done":     ("completed", None),
        "failed":   ("failed", None),
        "canceled": ("canceled", None),
    }
    if substrate_state not in table:
        raise LifecycleError(f"unknown substrate state: {substrate_state!r}")
    return table[substrate_state]
