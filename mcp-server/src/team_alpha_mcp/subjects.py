"""Subject taxonomy — single source of truth.

Mirrors MODEL.md and nats/auth.conf.example. Tool handlers compose subjects
from this module instead of hardcoding strings.
"""

# Per-agent
def agent_inbox(role: str) -> str:    return f"agents.{role}.inbox"
def agent_events(role: str) -> str:   return f"agents.{role}.events"

# Boards — production work
def task_pending(domain: str) -> str: return f"board.tasks.{domain}.pending"
def task_claimed(domain: str) -> str: return f"board.tasks.{domain}.claimed"
def task_blocked(domain: str) -> str: return f"board.tasks.{domain}.blocked"
def task_done(domain: str) -> str:    return f"board.tasks.{domain}.done"
def task_parked(domain: str) -> str:  return f"board.tasks.{domain}.parked"
def task_resumed(domain: str) -> str: return f"board.tasks.{domain}.resumed"
def task_progress(domain: str) -> str:return f"board.tasks.{domain}.progress"

# Learning — growth track (mentor-paired, scoped)
def learn_pending(domain: str) -> str:   return f"board.learning.{domain}.pending"
def learn_claimed(domain: str) -> str:   return f"board.learning.{domain}.claimed"
def learn_mentoring(domain: str) -> str: return f"board.learning.{domain}.mentoring"

# Results — finished work, broadly readable
def results(domain: str, kind: str = "shipped") -> str:
    return f"board.results.{domain}.{kind}"

# Broadcasts
BROADCAST_STANDUP   = "broadcast.standup"
BROADCAST_INCIDENTS = "broadcast.incidents"
BROADCAST_ANNOUNCE  = "broadcast.announcement"

# State KV (subject = $KV.team-state.<key>; here we expose the KV-key form)
def kv_project(pid: str) -> str:           return f"project.{pid}"
def kv_agent_load(role: str) -> str:       return f"agent.{role}.load"
def kv_agent_skills(role: str) -> str:     return f"agent.{role}.skills"
def kv_agent_human(role: str) -> str:      return f"agent.{role}.human"
def kv_agent_parked(role: str) -> str:     return f"agent.{role}.parked"
def kv_team_roster() -> str:               return "team.alpha.roster"
def kv_policy(name: str) -> str:           return f"policy.{name}"

# State events (live notifications mirroring KV)
def state_alert(kind: str) -> str:         return f"state.alert.{kind}"
def state_agent_human(role: str) -> str:   return f"state.agent.{role}.human"
def state_policy(name: str) -> str:        return f"state.policy.{name}"

# Domains recognized by the protocol
DOMAINS_PRODUCTION = ["python", "ui", "go", "terraform", "aws", "fullstack", "review"]
DOMAINS_LEARNING   = ["python", "ui", "go", "terraform", "aws"]
