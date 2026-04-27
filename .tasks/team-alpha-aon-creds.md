---
column: Done
created: 2026-04-27
shipped: 2026-04-27
order: 242
priority: high
parent: team-alpha-meta-aon-cli
---

> **Status (2026-04-27, slice 5):** `aon creds <role> [<dest>]`
> ships. Reads `nats/.passwords`, writes
> `~/.team-alpha/<role>.password` (chmod 600, dir 0700) by
> default. `aon creds --all` writes all per-role files in one
> shot (joiner-friendly). Smoke green.

# Card 242 — `aon creds <role>` — write per-role password file

Today after `aon auth set-passwords`, the operator (or joiner)
manually:

```bash
grep ^MIHAI= nats/.passwords | cut -d= -f2 > ~/.team-alpha/mihai.password
chmod 600 ~/.team-alpha/mihai.password
```

Easy to forget chmod. Easy to grep wrong key. Trivial to wrap.

## Goal

```bash
aon creds <role> [<dest>]
```

Reads `<team>/nats/.passwords`, looks up uppercase `<role>`,
writes the secret to `<dest>` (default
`~/.team-alpha/<role>.password`), chmod 600.

Print the path on stdout for piping if needed.

## Acceptance

- `aon creds mihai` writes `~/.team-alpha/mihai.password` with
  the right secret, mode 0600.
- Missing role / empty `.passwords` → non-zero exit + clear msg.
- `--all` writes per-role files for every entry in `.passwords`
  (joiner-friendly: replicates the entire team to disk).

## Why

Used by Card 241 (`aon launch`) internally; also useful
standalone to refresh creds after a password rotation.
