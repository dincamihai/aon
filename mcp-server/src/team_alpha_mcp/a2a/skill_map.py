"""Skill ↔ domain mapping (slice 2 card 132).

Skills (advertised in agents/<role>.json) and domains (in
subjects.DOMAINS_PRODUCTION) are 1:1 in the current taxonomy.
Wrap the mapping in a dedicated function so a future skill
extension (e.g. `python.django` → domain `python`) only has
one place to edit.
"""
from __future__ import annotations

from .. import subjects


def skill_to_domain(skill: str) -> str | None:
    """Return the substrate domain for `skill`, or None if no mapping."""
    if skill in subjects.DOMAINS_PRODUCTION:
        return skill
    # Slice 3 hook: split on dot and try the prefix (e.g. python.django).
    if "." in skill:
        prefix = skill.split(".", 1)[0]
        if prefix in subjects.DOMAINS_PRODUCTION:
            return prefix
    return None
