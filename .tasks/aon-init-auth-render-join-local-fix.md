---
column: InReview
assignee: tim
pr: https://github.com/dincamihai/aon/pull/68
---

# fix(aon): _aon_ensure_auth_ready + auto work-repo in join-local

Two fixes in `bin/aon`:

1. `_aon_require_nsc` — central NSC path check used by `cmd_auth_render`
2. `_aon_ensure_auth_ready` — NSC check + silent bootstrap if state absent.
   Wired into `cmd_nats_up` (replaces manual file checks) + `cmd_onboard`
3. `_cmd_join_local` — when cwd is team repo, use it as work-repo (was: warn + abort)

Awaiting review + e2e sign-off.
