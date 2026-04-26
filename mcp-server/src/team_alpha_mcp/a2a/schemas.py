"""A2A message schemas — slice 1 minimal subset.

JSON Schema-style validation via plain Python (no extra dep). Slice 2 may
swap to pydantic if richer typing pays off.
"""
from __future__ import annotations

from typing import Any


class SchemaError(ValueError):
    pass


def _require(d: dict, key: str, kind: type) -> Any:
    if key not in d:
        raise SchemaError(f"missing field: {key!r}")
    if not isinstance(d[key], kind):
        raise SchemaError(
            f"field {key!r} expected {kind.__name__}, got {type(d[key]).__name__}"
        )
    return d[key]


def validate_task_send(body: dict) -> None:
    """Shape of a2a.<role>.tasks.send request payload.

    Required: task_id (str), skill (str), payload (dict).
    Optional: parent_task_id (str), project_id (str), priority (str).
    """
    _require(body, "task_id", str)
    _require(body, "skill", str)
    _require(body, "payload", dict)
    for opt, kind in (
        ("parent_task_id", str),
        ("project_id", str),
        ("priority", str),
    ):
        if opt in body and not isinstance(body[opt], kind):
            raise SchemaError(
                f"optional field {opt!r} expected {kind.__name__}, "
                f"got {type(body[opt]).__name__}"
            )


def validate_status_update(body: dict) -> None:
    """Shape of a2a.<role>.tasks.<id>.status payload.

    Required: task_id (str), state (str).
    Optional: message (str), artifact (dict), reason (str).
    """
    _require(body, "task_id", str)
    _require(body, "state", str)
    for opt, kind in (
        ("message", str),
        ("artifact", dict),
        ("reason", str),
    ):
        if opt in body and not isinstance(body[opt], kind):
            raise SchemaError(
                f"optional field {opt!r} expected {kind.__name__}, "
                f"got {type(body[opt]).__name__}"
            )
