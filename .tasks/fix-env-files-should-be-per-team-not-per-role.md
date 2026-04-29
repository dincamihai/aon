---
column: Done
---

# Fix: .env files should be per-team, not per-role
joana.env has team-wide config (AON_NATS_URL, AON_WORK_REPO, AON_KV_BUCKET) that should apply to all roles equally.

Current state:
- Only joana.env exists despite multiple roles in roster
- When sun/tim/etc publish, they read from aon.toml (fallback)
- When joana publishes, it reads from joana.env

This creates port/url mismatches if joana.env diverges from aon.toml.

Design issue: Should be one .env per team with shared config, plus per-role .creds files. Not mixed per-role .env.

Related: join-link creates per-role .env with team config baked in (line ~1501 in bin/aon).
