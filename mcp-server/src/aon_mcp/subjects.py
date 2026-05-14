"""Subject taxonomy — single source of truth.

Mirrors MODEL.md and nats/auth.conf.example. Tool handlers compose subjects
from this module instead of hardcoding strings.
"""

TEAM_PREFIX = ""


def set_prefix(prefix: str) -> None:
    """Set team namespace prefix. All subject functions prepend it."""
    global TEAM_PREFIX
    TEAM_PREFIX = prefix.rstrip(".") if prefix else ""


def _p(subject: str) -> str:
    """Prepend team prefix if set."""
    return f"{TEAM_PREFIX}.{subject}" if TEAM_PREFIX else subject


class _Lazy:
    """Lazy subject — resolves prefix at stringification time, not import time."""
    def __init__(self, subject: str) -> None:
        self._subject = subject
    def __str__(self) -> str:
        return _p(self._subject)
    def __repr__(self) -> str:
        return repr(str(self))


# Per-agent
def agent_inbox(role: str) -> str:    return _p(f"agents.{role}.inbox")
def agent_events(role: str) -> str:   return _p(f"agents.{role}.events")

# Boards — production work
def task_pending(domain: str) -> str: return _p(f"board.tasks.{domain}.pending")
def task_claimed(domain: str) -> str: return _p(f"board.tasks.{domain}.claimed")
def task_blocked(domain: str) -> str: return _p(f"board.tasks.{domain}.blocked")
def task_done(domain: str) -> str:    return _p(f"board.tasks.{domain}.done")
def task_parked(domain: str) -> str:  return _p(f"board.tasks.{domain}.parked")
def task_resumed(domain: str) -> str: return _p(f"board.tasks.{domain}.resumed")
def task_progress(domain: str) -> str:return _p(f"board.tasks.{domain}.progress")

# Learning — growth track (mentor-paired, scoped)
def learn_pending(domain: str) -> str:   return _p(f"board.learning.{domain}.pending")
def learn_claimed(domain: str) -> str:   return _p(f"board.learning.{domain}.claimed")
def learn_mentoring(domain: str) -> str: return _p(f"board.learning.{domain}.mentoring")

# Results — finished work, broadly readable
def results(domain: str, kind: str = "shipped") -> str:
    return _p(f"board.results.{domain}.{kind}")

# Broadcasts — lazy: resolve prefix at use time, not import time
BROADCAST_STANDUP   = _Lazy("broadcast.standup")
BROADCAST_INCIDENTS = _Lazy("broadcast.incidents")
BROADCAST_ANNOUNCE  = _Lazy("broadcast.announcement")
BROADCAST_TEAM      = _Lazy("broadcast.team")

# State KV (subject = $KV.team-state.<key>; here we expose the KV-key form)
def kv_project(pid: str) -> str:           return f"project.{pid}"
def kv_agent_load(role: str) -> str:       return f"agent.{role}.load"
def kv_agent_human(role: str) -> str:      return f"agent.{role}.human"
def kv_agent_parked(role: str) -> str:     return f"agent.{role}.parked"
def kv_team_roster() -> str:               return "team.alpha.roster"
def kv_policy(name: str) -> str:           return f"policy.{name}"

# State events (live notifications mirroring KV)
def state_alert(kind: str) -> str:         return _p(f"state.alert.{kind}")
def state_agent_human(role: str) -> str:   return _p(f"state.agent.{role}.human")
def state_policy(name: str) -> str:        return _p(f"state.policy.{name}")

# A2A
def a2a_send(role: str) -> str:        return _p(f"a2a.{role}.tasks.send")
def a2a_cancel(role: str) -> str:      return _p(f"a2a.{role}.tasks.*.cancel")
def a2a_status(role: str, task_id: str) -> str: return _p(f"a2a.{role}.tasks.{task_id}.status")
def a2a_message(role: str, task_id: str) -> str: return _p(f"a2a.{role}.tasks.{task_id}.message")
def a2a_discovery(role: str) -> str:             return _p(f"a2a.discovery.{role}")

# Domains recognized by the protocol
DOMAINS_PRODUCTION = ["python", "ui", "go", "terraform", "aws", "fullstack", "review"]
DOMAINS_LEARNING   = ["python", "ui", "go", "terraform", "aws"]
