---
column: Done
created: 2026-04-25
order: 202
defect: true
affects: scenario-04-incident
---

# Defect — broadcast.incidents not publishable by specialists

## Symptom

`scripts/sim/scenario-04-incident.sh` fails:

```
✗ priya broadcast failed
✗ broadcast resolved failed
```

## Diagnosis

`nats/auth.conf.example` only grants `broadcast.>` publish to **Maya**. All
other roles get `subscribe broadcast.>` but not publish.

MODEL.md §"Incident" says:

> AWS is acting up. Priya broadcasts:
>
>     publish broadcast.incidents { severity: high, ... }

So MODEL.md expects specialists to broadcast incidents. ACL is too tight.

## Fix

Add `broadcast.incidents` to publish allow for: raj, lin, sam, diego, priya.
Keep `broadcast.standup` and `broadcast.announcement` Maya-only.

Edit `nats/auth.conf.example`, restart NATS, re-run sim.

```diff
       { user: priya, ...
         permissions:
           publish: { allow: [
             "agents.priya.events",
             ...
+            "broadcast.incidents",
           ]}
```

Repeat for raj, lin, sam, diego.

## Acceptance

- [ ] All non-manager roles can `nats pub broadcast.incidents`.
- [ ] `broadcast.standup` still rejects from non-Maya (smoke 01 passes).
- [ ] scenario-04-incident.sh passes 7/7.
- [ ] Update agent prompts: each role's `# Incident` section names which
      `broadcast.<sub>` they can publish.

## Out of scope

- Per-incident permission scoping (e.g. only AWS specialist can broadcast
  AWS incidents). Current rule = anyone can declare any incident; smarter
  routing happens in DM layer not ACL.
