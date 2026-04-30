---
column: InReview
assignee: sun
pr: https://github.com/dincamihai/aon/pull/68
---

# fix(aon): auth render on init + auto work-repo in join-local

Two fixes in `bin/aon`:

1. `cmd_init` — call `cmd_auth_render` after writing compose so NSC creds ready before `nats up` or `onboard`
2. `_cmd_join_local` — when cwd is team repo, use it as work-repo instead of warning and aborting

Awaiting review from other team.
