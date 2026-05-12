---
column: Backlog
created: 2026-05-06
order: 1110
priority: high
parent: aon-cmd-gate-ollama-classifier
related: aon-cmd-gate-acl-update, aon-destructive-ops-audit
---

# Card — `aon` cmd-gate: tamper-proofing inside the colima/AppArmor sandbox

ADR-001 ships cmd-gate as a `PreToolUse` hook on the Bash tool, with
the colima+AppArmor sandbox as the outer ring (`docs/sandbox.md`).
Today the gate reads almost every knob from environment variables
and from a per-worker `$HOME/.aon/security/` directory. Inside the
VM the agent is `ta-worker-<name>` and owns its own `$HOME`, so it
can mutate the gate's runtime configuration even though kernel-level
file/exec scoping is in place.

This card closes that gap: an agent inside the sandbox must not be
able to disable, weaken, or impersonate the gate by editing files,
shadowing binaries, swapping models, or exporting env vars.

## Threat model

Assume the agent process (`ta-worker-<name>` UID inside the VM) is
fully hostile but constrained by AppArmor + DAC. Goals it must not
achieve:

1. Run a destructive Bash call without the gate seeing it.
2. Make the gate auto-approve everything (bypass / fallback=allow / always-match local allow regex).
3. Replace the classifier model or its endpoint with a permissive one.
4. Edit the hook entry, the gate scripts, or the policy regex files.
5. Strip the audit publish so operator never sees the call.
6. Self-approve via `gate-reply` (already covered by ACL card 1101 — keep that invariant intact).

Out of scope: kernel exploits, host compromise via virtiofs escape.

## Mutation surfaces today

From `scripts/security/_lib.sh`:

| Surface | Today | Hostile use |
|---|---|---|
| `AON_GATE_ENABLED` env | reads env, default 1 | `AON_GATE_ENABLED=0` → gate no-op |
| `AON_GATE_BYPASS` env | reads env, default 0 | `AON_GATE_BYPASS=1` → skip layers 6–8 |
| `$GATE_LOCAL_DIR/bypass` marker | `[ -e ... ] && GATE_BYPASS=1` | `touch ~/.aon/security/bypass` from inside agent |
| `AON_GATE_MODEL` env | reads env | swap to a junk model that always says `allow` |
| `AON_GATE_OLLAMA_URL` env | reads env | point at attacker-controlled HTTP that returns `allow` |
| `AON_GATE_FALLBACK` env | reads env, default `ask` | `AON_GATE_FALLBACK=allow` → operator unavailable becomes allow |
| `AON_GATE_TIMEOUT_MS`, `AON_GATE_ASK_TIMEOUT` env | reads env | shrink to 0 → fallback fires immediately |
| `$GATE_LOCAL_DIR/{allow,deny}.local.regex` | per-worker `$HOME` | drop `^.*$` allow regex → allow everything |
| `scripts/security/cmd-gate.sh` and friends | resolved relative to `$AON_ENGINE_DIR` (env) | `AON_ENGINE_DIR=/tmp/fake` → run a fake gate |
| `.claude/settings.json` PreToolUse entry | inside the worktree (worker-owned) | remove the hook entry, gate never fires |
| `~/.claude/settings.json` (user level) | worker-owned `$HOME` | add a no-op hook that wins |
| `PATH` | worker-controlled | shadow `cmd-gate.sh` if hook resolves by basename |
| Audit publish | NATS account perms | already locked by ACL card 1101 — keep |

ADR-001 promises the bypass marker "lives outside the VM" — that's
only true if `~/.aon` is host-mounted; current `_lib.sh` resolves it
under the in-VM `$HOME`, which is worker-owned. Not actually
sandbox-tamper-proof yet.

## Goal

After this card:

- Gate config is a single root-owned file (`/etc/aon/gate.conf`).
  Env vars are ignored at runtime.
- Gate scripts, policy regex, and hook entry are root-owned and
  AppArmor-denied for write from any worker profile.
- Bypass marker, if it exists at all in the sandboxed mode, lives
  on a host-mounted ro path that the in-VM agent cannot create or
  delete.
- Hook entry in `.claude/settings.json` is bind-mounted ro from a
  root-owned canonical file; agent edits to the worktree copy have
  no effect.
- Hook command in `settings.json` uses an absolute path; PATH
  shadowing is moot.
- Classifier endpoint + model name come from `gate.conf` only and
  are pinned (URL on loopback, model name fixed; optional sha256
  pin once ollama exposes it).

## Deliverables

### 1. Trusted-config split in `_lib.sh`

Introduce a "trusted mode" flag that, when on:

- Reads every knob below from `/etc/aon/gate.conf` (root 0644). Env
  is **ignored** even if set.
- Resolves `$GATE_ENGINE_DIR` from a hard-coded absolute (`/usr/local/aon`)
  not from `AON_ENGINE_DIR`.
- Resolves `$GATE_LOCAL_DIR` from `gate.conf` (e.g.
  `/var/lib/team-alpha/sandbox/<role>/security`) — root-owned ro
  bind mount of host `~/.aon/security` if the operator wants
  personal overrides; otherwise empty/absent.

Knobs to move into `gate.conf`:

```
enabled = 1
bypass_marker = /var/lib/team-alpha/sandbox-shared/bypass   # absent in default sandbox
model = nemotron-3-nano:4b
ollama_url = http://127.0.0.1:11434
timeout_ms = 4000
ask_timeout = 60
fallback = ask          # ask | deny | allow
cache_ttl = 3600
local_dir = ""           # empty = no per-user overrides honoured
```

Trusted mode is detected by presence of `/etc/aon/trusted` (root 0644).
Outside the sandbox (host dev), absence of that file means env-var
mode continues to work — no regression for the laptop loop.

### 2. Filesystem ownership map

Update `scripts/sandbox/install-in-vm.sh` to install:

```
root:root 0755 /usr/local/aon/                                   (engine root)
root:root 0644 /usr/local/aon/scripts/security/policy/{allow,deny}.regex
root:root 0755 /usr/local/aon/scripts/security/*.sh
root:root 0644 /etc/aon/gate.conf
root:root 0644 /etc/aon/trusted                                  (marker)
root:root 0644 /etc/aon/claude-settings.json                     (canonical hook config)
```

Per-worker bind mount in the systemd unit:

```
BindReadOnlyPaths=/etc/aon/claude-settings.json:/work/workers/<name>/.claude/settings.json
BindReadOnlyPaths=/etc/aon/claude-settings.json:/var/lib/team-alpha/workers/<name>/.claude/settings.json
```

`add-worker.sh` ensures both target paths exist as empty files
before the bind mount, so the unit comes up cleanly.

### 3. AppArmor profile updates

In `scripts/sandbox/apparmor/team-alpha-worker`:

```
# gate code: read + execute, never write
/usr/local/aon/**                  r,
/usr/local/aon/scripts/security/*.sh   ix,
/usr/local/aon/bin/aon                 ix,
deny /usr/local/aon/**             w,
deny /etc/aon/**                   w,

# hook config in worktree: read-only even though path is under $HOME
deny /work/workers/*/.claude/settings.json  w,
deny owner /work/workers/*/.claude/settings.json w,

# user-level settings: not honoured
deny owner /var/lib/team-alpha/workers/*/.claude/settings.json w,

# bypass marker namespace: deny create/write inside VM
deny /var/lib/team-alpha/sandbox-shared/bypass w,
deny /var/lib/team-alpha/sandbox-shared/bypass l,

# ptrace hardening: cannot mutate gate process memory
deny ptrace,
```

VM sysctl (set in `install-in-vm.sh`):

```
kernel.yama.ptrace_scope = 2
```

### 4. Hook resolution by absolute path

`scripts/hooks/install.sh` (and the canonical `/etc/aon/claude-settings.json`)
must write the hook command as an absolute path:

```
"command": "/usr/local/aon/scripts/hooks/pre-tool-use.sh"
```

No `$PATH` lookup. `pre-tool-use.sh` resolves `cmd-gate.sh` via its
own `$BASH_SOURCE`-derived absolute path (already does), so PATH is
a non-factor on the inner call too.

### 5. Classifier endpoint pinning

- `ollama_url` in `gate.conf` is `http://127.0.0.1:11434` and the
  agent's NATS/network rules block all outbound except NATS + git
  remotes + pypi mirrors. Loopback to ollama allowed.
- Ollama runs as a different UID (e.g. `ollama:ollama`), socket on
  loopback, model directory root-owned. Worker cannot `ollama pull`
  to add a permissive model.
- Model name pinned in `gate.conf`. Optional follow-up: pin a sha256
  of the model blob once ollama exposes it; reject mismatch.

### 6. Doctor checks

`aon doctor` (sandbox mode) verifies:

- `/etc/aon/trusted` present and root-owned.
- `/etc/aon/gate.conf` root-owned 0644.
- `/usr/local/aon/scripts/security/cmd-gate.sh` root-owned 0755.
- Worker UID has read but not write on the above (statx + access(W_OK)
  reports EACCES).
- `.claude/settings.json` is a bind mount, not a regular file (check
  `findmnt`).
- `apparmor_parser -p` shows the worker profile loaded in enforce.
- Classifier reachable on the pinned URL and returns expected
  schema.

### 7. Tests (`scripts/hooks/tests/test-cmd-gate-tamper.sh`)

Run inside the VM as `ta-worker-<name>`:

- `AON_GATE_ENABLED=0 cmd-gate <bad>` → still denied.
- `AON_GATE_BYPASS=1 cmd-gate <bad>` → still denied (deny.regex floor) AND classifier still consulted on ambiguous (env ignored).
- `touch ~/.aon/security/bypass` → EACCES; gate behaviour unchanged.
- `AON_GATE_OLLAMA_URL=http://attacker.local cmd-gate <ambiguous>` → still calls 127.0.0.1.
- `AON_GATE_FALLBACK=allow cmd-gate <ambiguous, operator unavailable>` → fallback is whatever `gate.conf` says, not `allow`.
- `echo '^.*$' > ~/.aon/security/allow.local.regex` → either EACCES or ignored (because `local_dir = ""` in trusted mode).
- `cat /usr/local/aon/scripts/security/cmd-gate.sh > /tmp/x` then `/tmp/x <bad>` → AppArmor denies exec from `/tmp/`.
- Edit `.claude/settings.json` to remove hook → file is read-only (bind mount); write fails. Even if Claude Code were re-launched, `~/.claude/settings.json` is also read-only and ignored.
- `PATH=$HOME/bin:$PATH` with a fake `cmd-gate.sh` → hook in canonical settings calls absolute path, fake never executes.

All tests assert exact gate verdict + that AppArmor logs `apparmor="DENIED"` for the tamper attempts.

### 8. Doc updates

- `docs/sandbox.md` — new section "Gate-tamper hardening" describing the trusted-mode split, ownership map, bind-mount strategy, and ptrace hardening. Reference this card.
- `scripts/security/README.md` — clarify "knobs are env vars on host dev / file-only in sandbox". Update trust-model section: bypass marker is host-only and never reachable from inside the VM.
- ADR-001 — add a short addendum (not a new ADR; this is the implementation that already aligned with ADR-001's "complements the sandbox" stance).

## Acceptance

- All eight tamper tests pass inside the team-alpha VM in enforce mode.
- `aon doctor` (sandbox mode) reports green on a fresh `colima-up.sh` run.
- Host laptop (no `/etc/aon/trusted`) still works with env-var knobs — no regression for the existing solo dev loop.
- ADR-001 ACL card 1101 invariants still hold (no peer impersonation, no self-approval).
- `aa-status` shows `team-alpha-worker` in enforce mode with the new deny rules loaded.

## Out of scope

- Network egress allowlist via `nft` — separate work, already noted as
  non-goal in `docs/sandbox.md`.
- Seccomp-notify interactive prompts (Card 232) — orthogonal mechanism.
- Per-card path scoping via Landlock — orthogonal.
- Replacing PreToolUse hook with kernel-mandatory exec wrapper (Px transition through `classify-exec` for every binary). Considered and rejected during design discussion: ADR-001 already chose the dual-layer model (intent-classifier + capability-sandbox) over a unified mandatory-wrapper model. This card hardens that choice rather than redesigning around it.

## References

- [`docs/adr/001-cmd-gate-layered-safety-gate.md`](../docs/adr/001-cmd-gate-layered-safety-gate.md) — accepted layered design
- [`docs/sandbox.md`](../docs/sandbox.md) — colima/AppArmor outer ring
- [`.tasks/aon-cmd-gate-acl-update.md`](aon-cmd-gate-acl-update.md) — peer/self-approval lockdown (1101)
- [`scripts/security/_lib.sh`](../scripts/security/_lib.sh) — env-var knob surface to migrate
- [`scripts/sandbox/install-in-vm.sh`](../scripts/sandbox/install-in-vm.sh) — install path to extend
- [`scripts/sandbox/apparmor/`](../scripts/sandbox/apparmor/) — worker profile to extend
