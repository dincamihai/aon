"""Per-role allow/deny — mirrors nats/auth.conf.example.

Used for client-side pre-checks: reject locally before NATS roundtrip,
return a typed error explaining why. Server-side ACL is the source of
truth; this is a fast feedback layer for MCP clients (agents).
"""

from typing import Iterable

# Production-task domains a role can claim/block/done.
TASK_DOMAINS: dict[str, set[str]] = {
    "maya":  set(),                              # manager: posts tasks, never claims
    "mihai": set(),                              # manager (live): same shape as maya
    "raj":   {"python","ui","go","terraform","aws","fullstack","review"},
    "lin":   {"python","ui","go"},
    "vahid": {"python","go"},
    "sam":   {"ui"},
    "diego": {"go"},
    "priya": {"terraform","aws"},
}

# Learning-track domains a role can claim.
LEARNING_CLAIM_DOMAINS: dict[str, set[str]] = {
    "maya":  set(),
    "mihai": set(),
    "raj":   {"python","ui","go","terraform","aws"},     # senior; can also post learning
    "lin":   {"go"},
    "vahid": {"go"},
    "sam":   {"python","go"},
    "diego": {"terraform","aws"},
    "priya": {"python"},
}

# Roles allowed to offer mentoring on a domain.
MENTOR_DOMAINS: dict[str, set[str]] = {
    "maya":  set(),
    "mihai": set(),
    "raj":   {"python","ui","go","terraform","aws"},
    "lin":   set(),                              # mid; not mentoring yet
    "vahid": set(),
    "sam":   set(),
    "diego": set(),
    "priya": set(),
}

# Manager-only actions. Populated by __main__.py from aon.toml roster.
# Fallback for backward compat with old team-alpha configs.
MANAGER: set[str] = {"maya", "mihai"}


def set_managers(roles: set[str]) -> None:
    """Override MANAGER set — called from __main__.py after roster load."""
    global MANAGER
    MANAGER = set(roles)

# Roles allowed to publish results (production-shipped events).
RESULTS_DOMAINS: dict[str, set[str]] = {
    "maya":  set(),                              # explicitly denied
    "mihai": set(),
    "raj":   {"python","ui","go","terraform","aws","fullstack","review"},
    "lin":   {"python","ui","go"},
    "sam":   {"ui"},
    "diego": {"go"},
    "priya": {"terraform","aws"},
}


def can_claim_task(role: str, domain: str) -> tuple[bool, str]:
    if domain in TASK_DOMAINS.get(role, set()):
        return True, ""
    return False, (
        f"role={role} cannot claim production tasks in domain={domain}; "
        f"allowed domains: {sorted(TASK_DOMAINS.get(role, set())) or '(none)'}. "
        f"Try learning track if domain is in your growth list."
    )


def can_claim_learning(role: str, domain: str) -> tuple[bool, str]:
    if domain in LEARNING_CLAIM_DOMAINS.get(role, set()):
        return True, ""
    return False, (
        f"role={role} cannot claim learning tasks in domain={domain}; "
        f"allowed: {sorted(LEARNING_CLAIM_DOMAINS.get(role, set())) or '(none)'}."
    )


def can_post_task(role: str) -> tuple[bool, str]:
    if role in MANAGER:
        return True, ""
    return False, f"role={role} cannot post tasks; only manager (maya) may."


def can_post_results(role: str, domain: str) -> tuple[bool, str]:
    if domain in RESULTS_DOMAINS.get(role, set()):
        return True, ""
    return False, (
        f"role={role} cannot publish results for domain={domain}; "
        f"allowed: {sorted(RESULTS_DOMAINS.get(role, set())) or '(none, manager-denied)'}."
    )


def can_offer_mentoring(role: str, domain: str) -> tuple[bool, str]:
    if domain in MENTOR_DOMAINS.get(role, set()):
        return True, ""
    return False, (
        f"role={role} cannot offer mentoring on domain={domain}; "
        f"allowed: {sorted(MENTOR_DOMAINS.get(role, set())) or '(not a mentor role)'}."
    )


def must_be_manager(role: str) -> tuple[bool, str]:
    if role in MANAGER:
        return True, ""
    return False, f"role={role}: this action is manager-only (maya)."
