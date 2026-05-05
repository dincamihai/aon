---
column: Done
created: 2026-05-05
shipped: 2026-05-05
order: 1101
priority: high
parent: aon-cmd-gate-ollama-classifier
---

> **Status (2026-05-05, ACL verified):** Per-role NATS ACLs in place
> for the gate-request / gate-reply subjects. Smoke-tested on the
> workers team (rona, generalist, tester):
>
> - ✅ rona pubs on `evt.coord-in.gate-request.rona.<id>` → allowed
> - ✅ rona pubs on `evt.coord-in.gate-request.sun.<id>` → DENIED (no impersonation)
> - ✅ rona pubs on `evt.coord-out.gate-reply.rona.<id>` → DENIED (no self-approval; only sysadmin replies)
> - operator-ask.sh, cmd-gate.sh, watcher TUI, and `aon security {approve,deny}` CLI all use the role-qualified subject scheme.
>
> Existing teams must delete + re-mint user JWTs to pick up new perms:
> `nsc delete user --account <team> --name <role>` then `aon admin reinit`.
> templates/auth/*.tmpl + bin/_aon-lib.sh + scripts/nsc-smoke/run-smoke.sh
> all kept in sync. Drift signature mirror in `_aon_nsc_acl_sig`
> updated.

# Card — `aon` cmd-gate: NATS ACL for gate-request / gate-reply subjects

`aon-cmd-gate-ollama-classifier` introduced two new NATS subjects:

```
evt.coord-in.gate-request.<id>      gate → operator (deny/ask)
evt.coord-out.gate-reply.<id>       operator → gate
```

Today only `sysadmin` can use them (wildcard `>` perms in
[`templates/auth/sysadmin.tmpl`](../templates/auth/sysadmin.tmpl)). Worker
roles (`generalist`, `specialist`) and team `manager` roles have
narrower allowlists — they can't publish `gate-request` from inside the
agent. Operator-ask flow silently fails for those agents, gate falls
back to `AON_GATE_FALLBACK` (deny) instead of routing to the operator.

## Goal

Agents in any role kind can publish a gate-request and subscribe for
the matching reply. Operator (sysadmin) keeps wildcard read on all
requests. No role except sysadmin can publish gate-replies (otherwise
agents could "approve" themselves).

## Subject scheme adjustment

Add a role qualifier so per-role pub allow rules can target their own
namespace and not impersonate peers:

```
evt.coord-in.gate-request.<role>.<id>
evt.coord-out.gate-reply.<role>.<id>
```

Update:

- `scripts/security/operator-ask.sh` — emit `<role>.<id>` paths
- `scripts/security/cmd-gate.sh` — use new pattern in audit + sub
- `bin/aon` `cmd_security pending|approve|deny` — match new pattern
- `bin/aon-security-watch` — sub `evt.coord-in.gate-request.>` (wildcard,
  unchanged), but reply on `evt.coord-out.gate-reply.<role>.<id>` so
  the right agent gets it

## Auth template changes

```
templates/auth/generalist.tmpl
templates/auth/manager.tmpl
templates/auth/specialist.tmpl
```

Each gains:

```
publish.allow:
  "evt.coord-in.gate-request.@ROLE@.>"
subscribe.allow:
  "evt.coord-out.gate-reply.@ROLE@.>"
```

`templates/auth/sysadmin.tmpl` already has `>` wildcards — nothing to
change.

## Init flow

`aon admin init` already emits a sysadmin user (see
[bin/aon:524](../bin/aon)). No new role needed. Document in the README
that the human operator runs `aon security watch` under the sysadmin
identity (resolver already prefers sysadmin creds; this card just
ensures the agents can talk to that identity through the broker).

## Deliverables

- Subject scheme `<role>.<id>` end-to-end (gate, audit, TUI, CLI).
- Per-kind auth templates updated with the two new patterns.
- `aon admin reinit` regenerates auth.conf with the new perms.
- Docs in `scripts/security/README.md` explaining the subject scheme.
- Smoke test: launch a `generalist` role, ambiguous Bash, verify
  request reaches operator TUI; reply reaches the agent.

## Acceptance

- Agent in `generalist` kind can publish `evt.coord-in.gate-request.<role>.<id>`; cannot publish on any other role's path.
- Same agent can subscribe to its own `evt.coord-out.gate-reply.<role>.<id>` only.
- sysadmin can sub the wildcard request stream and pub replies to any role.
- A worker cannot self-approve by publishing a fake `gate-reply`.

## Out of scope

- Reply signing / authentication beyond NATS account-level (we trust
  NATS auth as the boundary). Operator identity in audit trail is the
  publishing account.

## References

- [`.tasks/aon-cmd-gate-ollama-classifier.md`](aon-cmd-gate-ollama-classifier.md) — parent
- [`templates/auth/`](../templates/auth/)
- [`bin/aon` — `_aon_nsc_ensure_user`](../bin/aon)
