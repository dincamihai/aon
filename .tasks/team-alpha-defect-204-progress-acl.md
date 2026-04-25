---
column: Done
created: 2026-04-25
order: 204
defect: true
affects: scenario-07-preempt-flow
---

# Defect — `board.tasks.<domain>.progress` publish denied for all non-Maya roles

## Symptom

`scripts/sim/scenario-07-preempt-flow.sh`: the `progress` publish silently
fails — no error displayed (output redirected to /dev/null), no "✓ priya
progress on low" line appears. Scenario passes anyway because the assertion
counts events on `board.>` aggregate which still has 4 from claimed/done/
shipped/pending.

```bash
as_role priya pub board.tasks.terraform.progress "$prog" >/dev/null 2>&1 \
  && ok "priya progress on low"   # never fires
```

## Diagnosis

`nats/auth.conf.example` per-role allow lists include
`board.tasks.<domain>.{claimed,blocked,done}` but NOT `.progress`. The
`progress` state is documented in MODEL.md and emitted by MCP tool
`progress_task` (card 110), but no role can actually publish it.

## Fix

Add `progress` to publish allow for each role's task domains:

```diff
       { user: priya, ...
         publish: { allow: [
           ...
           "board.tasks.terraform.claimed",
           "board.tasks.terraform.blocked",
           "board.tasks.terraform.done",
+          "board.tasks.terraform.progress",
           "board.tasks.aws.claimed",
           ...
+          "board.tasks.aws.progress",
```

Repeat for raj, lin, sam, diego, priya per their respective domain lists.

Alternative: refactor ACL to use `board.tasks.<domain>.>` allow + explicit
deny on `.pending` (which only Maya posts). One-line change per role,
auto-covers future states. **Recommend this path.**

## Acceptance

- [ ] All 5 non-Maya roles can publish `.progress` on their allowed
      domains.
- [ ] Maya still cannot claim/progress/done (manager doesn't execute).
- [ ] Smoke 01 (auth boundaries) passes — non-allowed domains still
      reject.
- [ ] Scenario 07's progress publish line ✓ passes after fix.

## Refactor opportunity (optional)

Replace per-state allow lists w/ `board.tasks.<domain>.>` + deny `.pending`
for each role. Reduces ACL line count by ~40, future-proofs new states like
`progress`, `parked`, `resumed`.

Trade-off: looser default (any new state under `board.tasks.<domain>.>`
auto-allowed). Acceptable since substrate-defined states are version-
controlled in this repo.

## Related

- card 110: MCP `progress_task` tool calls denied subject (will surface as
  ACL error to caller).
- defect-202: same shape (broadcast.incidents missing for specialists).
- defect-205 (next?): role ACLs include `parked` and `resumed`? Check —
  scenario 07 publishes `state.agent.priya.parked/resumed` which IS in
  `state.agent.<self>.>` allow. So those work. Only `.progress` is gapped.
