"""Per-role allow/deny — mirrors nats/auth.conf.example.

Used for client-side pre-checks: reject locally before NATS roundtrip,
return a typed error explaining why. Server-side ACL is the source of
truth; this is a fast feedback layer for MCP clients (agents).

Team aon-workers roles: sun (manager), tim (implementer), joana (reviewer),
rona (tester), ari (architect), mihai (operator-manager).
"""

from typing import Iterable

# ── Domains ──────────────────────────────────────────────────────────────
_DOMAIN_IMPLEMENTER  = {"implementer", "fullstack", "review"}
_DOMAIN_REVIEWER     = {"reviewer", "fullstack", "review"}
_DOMAIN_TESTER       = {"tester"}
_DOMAIN_ARCHITECT    = {"architect"}
_DOMAIN_MANAGER      = {"fullstack", "manager"}
_DOMAIN_NONE: set[str] = set()

# Production-task domains a role can claim/block/done.
TASK_DOMAINS: dict[str, set[str]] = {
    "sun":    _DOMAIN_NONE,    # manager: posts tasks, never claims
    "mihai":  _DOMAIN_NONE,    # operator-manager
    "tim":    _DOMAIN_IMPLEMENTER,
    "joana":  _DOMAIN_REVIEWER,
    "rona":   _DOMAIN_TESTER,
    "ari":    _DOMAIN_ARCHITECT,
    "mid":    _DOMAIN_MANAGER,
}

# Learning-track domains a role can claim.
LEARNING_CLAIM_DOMAINS: dict[str, set[str]] = {
    "sun":    set(),
    "mihai":  set(),
    "tim":    {"architect", "reviewer"},
    "joana":  {"architect", "implementer", "tester"},
    "rona":   {"architect", "implementer", "reviewer"},
    "ari":    {"implementer", "reviewer", "tester"},
    "mid":    set(),
}

# Roles allowed to offer mentoring on a domain.
MENTOR_DOMAINS: dict[str, set[str]] = {
    "sun":    {"fullstack", "implementer", "reviewer", "tester", "architect"},
    "mihai":  {"fullstack", "implementer", "reviewer", "tester", "architect"},
    "tim":    {"implementer"},
    "joana":  {"reviewer"},
    "rona":   set(),
    "ari":    {"architect"},
    "mid":    set(),
}

# Manager-only actions. Populated by __main__.py from aon.toml roster.
MANAGER: set[str] = {"sun", "mihai"}


def set_managers(roles: set[str]) -> None:
    """Override MANAGER set — called from __main__.py after roster load."""
    global MANAGER
    MANAGER = set(roles)

# Roles allowed to publish results (production-shipped events).
RESULTS_DOMAINS: dict[str, set[str]] = {
    "sun":    set(),    # explicitly denied (poster, not doer)
    "mihai":  set(),
    "tim":    _DOMAIN_IMPLEMENTER,
    "joana":  _DOMAIN_REVIEWER,
    "rona":   _DOMAIN_TESTER,
    "ari":    _DOMAIN_ARCHITECT,
    "mid":    _DOMAIN_MANAGER,
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
    return False, f"role={role} cannot post tasks; only managers may."


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
    return False, f"role={role}: this action is manager-only."
