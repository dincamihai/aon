#!/usr/bin/env bash
# EC2 bootstrap: install nats-server, mount EBS, write systemd unit.
# Runs once at instance launch via user_data. Safe to re-run (idempotent).
set -euo pipefail

NATS_VERSION="${nats_version}"    # substituted by Terraform templatefile()
EBS_DEVICE="/dev/xvdf"
NATS_DATA="/var/lib/nats"
NATS_USER="nats"
NATS_BIN="/usr/local/bin/nats-server"

# ── EBS mount ──
if ! blkid "$EBS_DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -L nats-data "$EBS_DEVICE"
fi
mkdir -p "$NATS_DATA"
if ! grep -q "$EBS_DEVICE" /etc/fstab; then
  echo "$EBS_DEVICE  $NATS_DATA  ext4  defaults,nofail  0  2" >> /etc/fstab
fi
mount -a

# ── nats-server binary (ARM64) ──
if [[ ! -x "$NATS_BIN" ]]; then
  ARCH="linux-arm64"
  TARBALL="nats-server-v${NATS_VERSION}-${ARCH}.tar.gz"
  URL="https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/${TARBALL}"
  curl -sSL "$URL" -o "/tmp/${TARBALL}"
  tar -xz -f "/tmp/${TARBALL}" -C /tmp
  install -m 755 "/tmp/nats-server-v${NATS_VERSION}-${ARCH}/nats-server" "$NATS_BIN"
  rm -rf "/tmp/nats-server-v${NATS_VERSION}-${ARCH}" "/tmp/${TARBALL}"
fi

# ── nats user ──
id "$NATS_USER" >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d "$NATS_DATA" "$NATS_USER"
chown -R "$NATS_USER:$NATS_USER" "$NATS_DATA"

# ── nats config ──
mkdir -p /etc/nats
cat > /etc/nats/nats-server.conf <<'CONF'
# aon NATS — JetStream enabled, auth from operator bootstrap.
# Private subnet: no public interface needed.
# Auth config is written at bootstrap time by operator via SSM send-command.

port: 4222

jetstream {
  store_dir: /var/lib/nats/jetstream
  max_memory_store: 256MB
  max_file_store: 4GB
}

# Auth block placeholder — operator writes this via:
#   aws ssm send-command --document-name AWS-RunShellScript \
#     --parameters 'commands=["cat > /etc/nats/auth.conf <<EOF ..."]' \
#     --instance-ids <instance-id>
# Then: systemctl reload nats
include /etc/nats/auth.conf;
CONF
chown root:root /etc/nats/nats-server.conf
chmod 644 /etc/nats/nats-server.conf

# Stub auth.conf so nats-server starts without auth on first boot.
# Operator replaces this via SSM send-command before any agent connects.
if [[ ! -f /etc/nats/auth.conf ]]; then
  cat > /etc/nats/auth.conf <<'AUTH'
# Placeholder — replace with real credentials before connecting agents.
# See: aon bootstrap (post-JWT migration) or operator runbook.
AUTH
  chmod 600 /etc/nats/auth.conf
fi

# ── systemd unit ──
cat > /etc/systemd/system/nats.service <<'UNIT'
[Unit]
Description=NATS Server
After=network.target local-fs.target

[Service]
User=nats
Group=nats
ExecStart=/usr/local/bin/nats-server -c /etc/nats/nats-server.conf
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable nats
systemctl start nats || systemctl restart nats
