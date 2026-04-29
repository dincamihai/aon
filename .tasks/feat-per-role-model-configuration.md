---
column: Backlog
---

# feat: per-role model configuration
Each role should have its own model config instead of single global [model] in aon.toml.

Use case: sun with gemma (fast), rona with qwen (reasoning). Currently all roles use same model from [model] section.

Could be:
- Add optional `model` field to [[roles]] in toml
- Fall back to global [model] if role doesn't specify
- Pass model selection to claude/ollama launch based on role

Affects: cmd_launch model resolution, possibly env setup.
