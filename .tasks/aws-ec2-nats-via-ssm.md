---
column: Backlog
created: 2026-04-28
order: 60
priority: high
related: onboarding-overhaul
---

# Deploy NATS on tiny EC2 in AWS dev; tunnel via SSM

Move the team's NATS substrate off operator laptop (docker compose +
cloudflared tunnel) onto a tiny EC2 in the AWS dev account. Operators
+ joiners reach it via AWS SSM port-forwarding, not public ingress.

## Why

- **Always-on**: laptop closes lid → all agents lose substrate.
  Cloud NATS = persistent across operator sleep/restart.
- **No public exposure**: SSM tunnels via IAM-authenticated session.
  No security group ingress, no Cloudflared subdomain leakage,
  no anon URL.
- **Auditable access**: every connect = an SSM session in CloudTrail.
  Beats "who has the bits this week" tracking.
- **Replaces fragile cloudflared bits**: the `aon set-nats-url BITS`
  tunnel rotation + leaked-URL spam class of bugs goes away.
- **Cheap**: t4g.nano ARM (~$3/mo) + small EBS. NATS sub-100MB RSS,
  fits easily.

## End state

```bash
# operator one-time per box
aws sso login --profile aon-dev
aon tunnel up   # starts SSM port-forward NATS:4222 → localhost:4222

# from anywhere
aon monitor     # connects via localhost:4222 → SSM → EC2 NATS
```

NATS URL for everyone becomes static: `nats://localhost:4222`.
The "tunnel" is the SSM session, started on demand per operator box.

## Architecture

```
operator laptop                AWS dev account
+----------------+             +-----------------------+
| aon tunnel up  |  SSM       | EC2 t4g.nano (private) |
| → localhost    |─────────►   | nats-server :4222      |
|   :4222        |   port-fwd | systemd unit           |
+----------------+             | persistent EBS auth    |
                               +-----------------------+
```

- EC2: private subnet, no public IP, IAM role with
  `AmazonSSMManagedInstanceCore`, security group allows nothing
  inbound (SSM uses SSM endpoint, not SG).
- NATS: pinned version, systemd unit, `auth.conf` (or `.creds` post
  `nsc-jwt-migration`) on EBS volume.
- JetStream: persistent on EBS so streams survive instance replace.
- IaC: one Terraform module under `infra/aws-nats/`. Reusable across
  dev/staging/prod accounts.

## Sub-tasks

### 1. Terraform module

`infra/aws-nats/` — single VPC/subnet/EC2/EBS, IAM role for SSM,
security group with zero ingress, `user_data` installs nats-server +
writes systemd unit + mounts EBS. Outputs: instance ID + region.

### 2. NATS systemd unit

`/etc/systemd/system/nats.service` — restart=always, reads config
from `/var/lib/nats/`, JetStream store on EBS mount.

### 3. Auth bootstrap

Pre-NSC: drop `auth.conf` via SSM `aws ssm send-command` from
operator box. Post-NSC (`nsc-jwt-migration`): operator JWT + resolver
dir on EBS, `nsc push` over SSM tunnel.

### 4. `aon tunnel up/down/status`

New `aon` subcommand wrapping:

```bash
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=["4222"],localPortNumber=["4222"]' \
  --profile aon-dev
```

Background it, write PID + ssm-session-id to `~/.aon/tunnel.state`.
`aon tunnel down` kills + cleans state. `aon tunnel status` shows
session-id, instance, age.

### 5. Resolve URL via tunnel state

`aon resolve-env` checks tunnel state file; if active and pointing
to localhost:4222, sets `AON_NATS_URL=nats://localhost:4222`. Else
falls back to whatever's in `<role>.env`. Removes the manual URL
juggling.

### 6. Doctor checks

`aon doctor` adds:
- AWS CLI present + `aws-cli@v2`
- `aws sso login` session valid (`aws sts get-caller-identity`)
- `session-manager-plugin` installed
- Tunnel up + reachable on localhost:4222

### 7. Replace cloudflared in onboard / join flows

`aon onboard` no longer prompts for BITS. URL is implicit
(`nats://localhost:4222` once tunnel up). `aon set-nats-url` becomes
a no-op (deprecate after grace period).

## Cost guard

- t4g.nano: $0.0042/hr (~$3/mo).
- 8 GB gp3 EBS: ~$0.80/mo.
- SSM session: free.
- CloudWatch logs (NATS stdout): keep short retention (7d).
- Tag everything `team=aon`, `cost-center=dev` for billing visibility.
- Stop instance off-hours? Probably not worth the complexity at $3/mo.

## Failure modes + recovery

- **EC2 instance lost**: Terraform `apply` recreates; EBS volume
  retains JetStream state. NATS restarts, agents reconnect.
- **EBS lost**: stream state lost (acceptable for current usage —
  no persistent business data). Document "rerun bootstrap" runbook.
- **AWS SSO expired**: `aws sso login` refresh; tunnel restart.
- **Region outage**: dev-tier, accept downtime. Don't multi-region.

## Acceptance

- Terraform `apply` from clean state spins up EC2 + EBS + NATS in
  ≤5 minutes.
- Operator can `aon tunnel up` and `aon monitor` works without any
  cloudflared/public-URL config.
- All current agents reconnect to `nats://localhost:4222` (no role
  prompt changes).
- Zero security-group ingress rules. `nmap` from public IP returns
  nothing.
- `aws ssm start-session` recorded in CloudTrail per connect.
- `aon doctor` pre-flights tunnel + AWS auth.

## Out of scope

- Multi-region failover.
- Production tier (separate card later — different acct, different
  HA posture, NSC required).
- Replacing `aon nats up` for purely-local dev iterations (keep
  docker-compose path as offline option).
- Customer-facing NATS exposure.

## Dependencies

- Optional but recommended: `nsc-jwt-migration` lands first so
  remote auth uses JWT not shared password file.
- Independent of `waiting-room-admit` — that card defines the
  joiner flow; this card defines where the substrate runs.
