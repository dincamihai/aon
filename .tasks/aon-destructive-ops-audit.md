---
column: Backlog
priority: medium
created: 2026-04-30
owner: ""
parent: rona-audit-aon-destructive-ops.md
---

# Audit: destructive ops in aon

Scope per `~/Repos/workers/.tasks/rona-audit-aon-destructive-ops.md`:
`bin/aon`, `bin/_aon-lib.sh`, `scripts/**/*.sh`, `mcp-server/**/*.py` in
`~/Repos/ai-over-nats`. Audit-only — implementation is a follow-up.

Cross-link: `aon-prompts-render-non-destructive.md` covers `cmd_prompts_render` (already guarded with `--force`).

## Executive summary

| Class | Count |
|------:|:------|
| Always destructive (no guard) | 4 |
| Guarded (--force / interactive prompt / requires arg) | 5 |
| Conditional (only if target exists in specific shape) | 7 |

**Top 3 highest-risk paths:**

1. **`aon admin nats down`** (`bin/aon:879`) — runs `${AON_CONTAINER_CMD} stop $cname && rm $cname` unconditionally. No `--force` flag. Single command takes the shared NATS container down for **every team on the host**. With shared-NATS migration (post-PR#63) this is now multi-tenant impact; pre-migration it was per-team.
2. **`aon admin reinit <role>`** (`bin/aon:632`) — single-role re-issue runs `nsc delete user --account "$team" "$role"` unconditionally before re-issuing. Any outstanding `<role>.creds` file in the wild becomes invalid the moment this fires. No confirmation prompt, no `--force`.
3. **`aon admin revoke <role>`** (`bin/aon:1001`) — `nsc revocations add-user` + `nsc push` immediately invalidates outstanding creds. Documented destructive but operates on a single positional arg with no confirm. A typo on the role name silently revokes the wrong agent.

## Inventory

| ID | Command verb | File:line | What gets destroyed | Current guard | Recommended |
|----|--------------|-----------|---------------------|---------------|-------------|
| D-01 | `aon admin nats down` | `bin/aon:879` (`cmd_nats_down`) | Stops + removes shared `aon-nats-1` container — affects ALL teams sharing the host NATS | none | confirm prompt or `--force`; refuse when other teams have connected creds in last N min |
| D-02 | `aon admin reinit <role>` | `bin/aon:660` (`cmd_reinit`, single-role branch) | `nsc delete user`, invalidates outstanding `<role>.creds` for every joiner who has them | none | confirm prompt; or require `--force` when `nsc revoke` history shows none for the role |
| D-03 | `aon admin revoke <role>` | `bin/aon:1001` (`cmd_revoke`) | `nsc revocations add-user` + immediate JWT push; invalidates outstanding creds | matches `nsc describe user` first to fail fast on typos | add explicit confirm `Revoke <role>? [y/N]` (interactive) or `--yes` for scripted |
| D-04 | `aon connect TOKEN BITS` writes `<work_repo>/CLAUDE.md` | `bin/aon:1437` (`_aon_install_repo_mcp`) | Overwrites existing `CLAUDE.md` if no `AON-MARKER-…` block (else appends or refreshes-in-place) | conditional (marker check) | document; flag: append even when no marker is fine, but `printf > "$repo_claude_md"` runs only when file MISSING — currently safe-by-condition |
| D-05 | `aon connect TOKEN BITS` writes `<work_repo>/.gitignore` | `bin/aon:1296` area (sed-append) | Mutates committed `.gitignore` (adds `.mcp.json`) | append-only via grep-then-append | safe by inspection; flag for awareness |
| D-06 | `aon connect TOKEN BITS` writes `<work_repo>/.mcp.json` | `bin/aon:1291` (jq merge into temp + mv) | Overwrites — but uses jq merge to preserve existing keys | conditional (jq merge preserves user keys) | safe by jq merge; document and unit-test |
| D-07 | `aon connect TOKEN BITS` writes `<work_repo>/.claude/settings.json` | `bin/aon:1350` (`$repo_settings.tmp` + mv) | Overwrites the joiner's per-repo claude settings with rendered version | conditional (jq merge of hooks; not a full clobber) | safe by jq merge; ensure tests cover pre-existing settings.json |
| D-08 | `aon admin tunnel up` writes `~/.aon/tunnel.state` | `bin/aon:2343` (`cat > "$state"`) | Truncates state file with new PID block | rejects if existing PID still alive (safe), else `rm -f` + recreate | safe by alive-check; document |
| D-09 | `aon admin tunnel down` removes state file | `bin/aon:2371` (`rm -f "$state"`) | Wipes tunnel state | requires existing state; prints warning if pid not running | safe |
| D-10 | `aon admin tick uninstall <name>` | `bin/aon:2741` | `launchctl unload` + `rm -f $plist` (or systemd disable + rm units) | requires positional `<name>`; prints message if not found | safe; consider listing matching ticks before delete |
| D-11 | `aon admin migrate local-toml` | `bin/aon:2629` (`cmd_migrate_local_toml`) | Strips `[nats] url` from repo `aon.toml`; writes/updates `~/.aon/teams/<team>/aon-local.toml` | conditional (idempotent: skips if no url) | safe but advise dry-run + git-diff prompt |
| D-12 | `aon admin reinit` (full, no role) | `bin/aon:677` (`cmd_reinit` no-arg) | Runs auth render + bootstrap + prompts render. Prompts render is `--force=0` so existing files are SKIPPED, not overwritten | guarded via `cmd_prompts_render --force`-gating | safe; document that reinit is non-destructive on prompts (matches PR#50) |
| D-13 | `aon admin onboard NAME` | `bin/aon:1657` (`cmd_onboard`) | Multi-step. Adds NSC user + creates creds + writes prompt files (skipped if exist). Calls SIGHUP NATS or compose --force-recreate | conditional (prompts skipped, NATS recreate only on SIGHUP failure) | safe; document the recreate fallback path |
| D-14 | `aon admit approve` | `bin/aon:2571` (`cmd_admit_approve`) | `kv del request.${box_id}` after writing reply | conditional on a successful reply write | safe |
| D-15 | `aon admit reject` | `bin/aon:2591` (`cmd_admit_reject`) | `kv del request.${box_id}` | unconditional once reply is written | safe |
| D-16 | `nsc delete user` in `cmd_auth_render` ACL-drift fixer | `bin/aon:520` | nsc-deletes a user when ACL drift detected; just-in-time recreated | runs only when drift detected; warning emitted | safe |
| D-17 | `cmd_prompts_render` overwrite | `bin/aon:385–449` | Overwrites `agent-prompts/*.md` only when `--force` given | `--force` flag required | already correct (see PR#50 + cross-linked card) |
| D-18 | `scripts/coordinator-watcher.sh` truncates state files | `coordinator-watcher.sh:64,79,142` (`> "$claims_file"`) | Empties claim/result/parked/a2a-status state files at watcher start | always truncates on watcher startup; in-memory only | safe (designed as ephemeral watcher state) |
| D-19 | `scripts/worktree-claim.sh` runs `git reset --hard HEAD^` | `worktree-claim.sh:78` | Hard-resets worker branch one commit | runs only inside throwaway worktree; trap cleans up | safe by isolation; document |
| D-20 | `scripts/worktree-cleanup.sh` runs `git branch -D` | `worktree-cleanup.sh:72` | Force-deletes worker branch | runs against the worktree-private branch only | safe by naming convention; could add safety check that branch isn't checked out elsewhere |
| D-21 | `scripts/migrate-2026-04-skills-kv.sh` runs `kv del -f` on `team-state` keys | `migrate-2026-04-skills-kv.sh:19` | Force-deletes specific KV keys in production bucket | one-time migration script | safe-by-design but wrap with operator-confirm on first run |
| D-22 | mcp-server `js.delete_consumer` | `mcp-server/src/aon_mcp/client.py:225` and `build/lib/.../client.py:219` | Deletes a JetStream consumer | runs as part of cleanup logic in client | safe by intent; verify build/ copy isn't stale (looks like duplicate of src/) |
| D-23 | `nats kv del` in waiting-room (cmd_admit) | `bin/aon:2571,2591` | Removes waiting-room request key after approve/reject | conditional on reply write success | safe |

## Reproductions for the Top 3

### D-01: `aon admin nats down` takes the shared container down

```bash
# Two teams share aon-nats-1 (post-shared-nats migration).
# Team A's operator runs:
aon admin nats down
# → docker stop aon-nats-1 + docker rm aon-nats-1
# → Team B's agents lose the substrate. No warning.
```

### D-02: `aon admin reinit <role>` invalidates outstanding creds

```bash
# Joiner has alice.creds in their pocket, agent is happily running.
# Operator runs (e.g. to re-mint after a typo):
aon admin reinit alice
# → nsc delete user --account <team> alice + re-issue
# → joiner's existing alice.creds still has old subject; subsequent
#   pubs/subs hit Authorization Violation. No warning to operator.
```

### D-03: `aon admin revoke <role>` typo

```bash
# Operator means to revoke "ali" but typo:
aon admin revoke alice
# → nsc revocations add-user + push
# → alice's creds invalidated immediately, agent dropped from substrate.
# Currently fast-fails on unknown role names but accepts any role IN
# the roster without confirmation.
```

## Method

1. Greps run from `~/Repos/ai-over-nats` for: `\brm\s+-[rfRF]+`, `git (reset --hard|checkout --|branch -D|push --force|clean -[fd]+)`, `> *"\$`, `truncate`, `nsc (delete|revoke)`, `kv (del|purge|destroy|rm)`, `stream (rm|delete|purge)`, `--force`, `os\.remove|shutil\.rmtree|unlink|truncate|delete`.
2. Each hit walked back to its `cmd_*` entry-point in `bin/aon` (dispatch table at `bin/aon:2794–2810`).
3. Hits classified along the destructive/conditional/guarded axis.

## Tester note (rona, black-box constraint)

This card required source reading, which is normally outside rona's scope per `agent-prompts/rona.md`. Card was authored by mid+sun specifically as a static read-only audit (the parent card explicitly says "Repo: ai-over-nats (read-only audit)"). I treated the source as data, not as a debugging aid for runtime behavior — kept the audit scoped to "what can the user ask the tool to do that destroys state" and did not chase down internal call graphs beyond identifying the user-facing entry-point and its destructive sub-call.

## Out of scope

- Implementing the guards. Recommendation column is advisory only.
- Verifying the destructive ops empirically (would require reproducing each scenario; the inventory is the deliverable).
- Reviewing destructive ops in the workers repo or any joiner's work-repo (not in audit scope).
