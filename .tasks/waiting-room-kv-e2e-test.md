---
column: Backlog
priority: critical
created: 2026-04-29
parent: waiting-room-natscore-race-joiner-req-lost.md
owner: rona
blocked-by:
  - waiting-room-cmd-connect-kv-rewrite.md
  - waiting-room-cmd-admit-list-and-approve-reject.md
---

# Subtask 4/5: e2e smoke test for KV-based waiting-room

Verify the fix actually fixes the race + downstream symptoms.

## Cases to cover

Add a new test in `scripts/nsc-smoke/` (or extend an existing waiting-room smoke if one already lives there). Each case starts from a clean team init.

### A. Connect-before-admin (the original Bug 4 repro)

1. Bring up team workers + NATS.
2. Start `aon connect nats://localhost:4322 workers` in background. Capture stdout/exit.
3. Wait 2s.
4. Run `aon admit list workers`. Expect: 1 pending request shown.
5. Run `aon admit approve workers <box_id> sun`.
6. Joiner unblocks, exits 0, prints success.

### B. Admin-listing-first

1. Run `aon admit list workers` once → "no pending requests".
2. Start `aon connect ...` in background.
3. After 2s: `aon admit list workers` shows the request.
4. Approve. Joiner unblocks.

### C. Two concurrent joiners

1. Two `aon connect ...` in background, different shells.
2. `aon admit list workers` → 2 pending, distinct box_ids.
3. Approve one with role A, reject the other with reason "test".
4. Both joiners unblock with the matching outcome.

### D. Reject path

1. `aon connect ...` in background.
2. `aon admit reject workers <box_id> "manual test"`.
3. Joiner exits non-zero, prints "manual test".

### E. TTL cleanup

1. Set bucket TTL to 60s for the test (override or use a separate test bucket).
2. `aon connect ...`, then kill the joiner.
3. Wait 70s.
4. `nats kv ls <bucket>` shows the request key gone.

### F. Regression — rest of the substrate

Re-run rona's existing smoke checklist against the fix branch:

- `aon doctor`, `aon resolve-env`
- `aon pub` / `aon sub` round-trip
- role-monitor stays alive
- mcp-server happy path
- ollama launcher
- hook launcher

Expect zero regressions.

## Acceptance

1. All 6 cases pass.
2. Capture trace output for cases A–E (joiner stdout + admin stdout + bucket state). Attach to the test-done DM.
3. No `Permissions Violation` in NATS logs during normal flow.
4. NATS logs are quiet on startup (no read-only resolver fs JWT push errors — separate pre-existing issue, but flag if it recurs).

## Reporting

DM `agents.sun.inbox` with:

```json
{"type":"test-done","from":"rona","card":"waiting-room-kv-e2e-test","branch":"<branch>","commit":"<sha>","results":{"A":"PASS|...","B":"...","C":"...","D":"...","E":"...","F":"PASS|notes"},"regressions":[],"verdict":"ready-for-final|changes-needed|blocked"}
```
