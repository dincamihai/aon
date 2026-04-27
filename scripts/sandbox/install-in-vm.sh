#!/usr/bin/env bash
# install-in-vm.sh — provisioner that runs INSIDE the colima VM as root.
#
# Installs apparmor-utils, creates team-alpha users, drops profiles, loads
# them, installs systemd units, sets up /work tree.
#
# Invoked by colima-up.sh. Safe to re-run.

set -euo pipefail

HARNESS=""
PROJECT=""
LOCAL_APPARMOR=""
AA_MODE="${TA_AA_MODE:-enforce}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --local-apparmor) LOCAL_APPARMOR="$2"; shift 2 ;;
    --aa-mode) AA_MODE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$HARNESS" ]] || { echo "install: --harness required" >&2; exit 1; }
[[ -n "$PROJECT" ]] || { echo "install: --project required" >&2; exit 1; }
[[ -d "$HARNESS" ]] || { echo "install: harness path not visible inside VM: $HARNESS" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "install: must run as root inside VM" >&2; exit 1
fi

echo "install: apt update + packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  acl \
  apparmor apparmor-utils apparmor-profiles \
  auditd \
  ca-certificates curl git jq nftables \
  nodejs npm \
  nats-server \
  systemd

# apt enables stock nats-server.service which grabs 127.0.0.1:4222.
# We run NATS via our own hardened unit on the same port. Mask stock.
systemctl disable --now nats-server.service 2>/dev/null || true
systemctl mask nats-server.service 2>/dev/null || true

echo "install: enable apparmor + auditd"
systemctl enable --now apparmor auditd nftables

# ---------- users + dirs ----------
echo "install: users + /work tree"
getent group team-alpha >/dev/null || groupadd --system team-alpha
id ta-coord >/dev/null 2>&1 || \
  useradd --system --create-home --home-dir /var/lib/team-alpha/coord \
          --shell /usr/sbin/nologin --gid team-alpha ta-coord

install -d -m 0755 -o root     -g root       /work
install -d -m 0700 -o ta-coord -g team-alpha /work/coord
install -d -m 0755 -o root     -g team-alpha /work/workers
install -d -m 0755 -o root     -g root       /etc/team-alpha
install -d -m 0755 -o root     -g root       /var/log/team-alpha
install -d -m 0755 -o root     -g root       /var/lib/team-alpha
install -d -m 0755 -o root     -g team-alpha /var/lib/team-alpha/workers

# ---------- claude binary ----------
# Install via npm — official Linux distribution method. Lands at
# /usr/local/bin/claude, owned by root, world-readable.
if ! command -v claude >/dev/null; then
  echo "install: claude not on PATH — installing via npm"
  npm install -g --silent @anthropic-ai/claude-code || \
    echo "install: claude install failed; install manually before starting units" >&2
fi
command -v claude >/dev/null && claude --version || true

# ---------- AppArmor profiles ----------
echo "install: AppArmor profiles"
SRC="$HARNESS/scripts/sandbox/apparmor"
install -m 0644 "$SRC/abstractions/team-alpha-base"   /etc/apparmor.d/abstractions/team-alpha-base
install -m 0644 "$SRC/team-alpha-coord"               /etc/apparmor.d/team-alpha-coord
install -m 0644 "$SRC/team-alpha-worker"              /etc/apparmor.d/team-alpha-worker

# Personal/local overrides. User keeps edits on host at $HOME/.team-alpha/apparmor/{base,coord,worker};
# we sync them into /etc/apparmor.d/local/ on every install. Stubs created if missing
# so #include if exists picks them up cleanly even when empty.
install -d -m 0755 /etc/apparmor.d/local
LOCAL_SRC="${LOCAL_APPARMOR:-${TA_LOCAL_APPARMOR:-}}"
for kind in base coord worker; do
  TARGET="/etc/apparmor.d/local/team-alpha-$kind"
  if [ -n "$LOCAL_SRC" ] && [ -f "$LOCAL_SRC/$kind" ]; then
    install -m 0644 "$LOCAL_SRC/$kind" "$TARGET"
    echo "install: synced local override $LOCAL_SRC/$kind → $TARGET"
  elif [ ! -f "$TARGET" ]; then
    cat > "$TARGET" <<EOF
# Personal AppArmor overrides for team-alpha-$kind.
# AppArmor unions allow + deny; deny always wins. This file can tighten
# (deny extra paths) or extend (allow extra paths) the shared profile.
#
# Edit on host:  ~/.team-alpha/apparmor/$kind
# Apply:         re-run colima-up.sh, or:
#                colima ssh -- sudo /Users/.../scripts/sandbox/reload-apparmor.sh
#
# Examples:
#   # Deny a whole subtree. Note: AppArmor ** does NOT match the
#   # directory entry itself, so deny BOTH the dir and **.
#   deny /Users/me/Repos/secrets/    rwklx,
#   deny /Users/me/Repos/secrets/**  rwklx,
#
#   # Allow a tool not in the base abstraction.
#   /opt/my-tool/** rix,
EOF
    chmod 0644 "$TARGET"
  fi
done

# Reload profiles. Default mode = enforce. Override with TA_AA_MODE=complain
# at first deploy to harvest logs via aa-logprof, then re-run to enforce.
apparmor_parser -r /etc/apparmor.d/team-alpha-coord
apparmor_parser -r /etc/apparmor.d/team-alpha-worker
case "$AA_MODE" in
  enforce)  aa-enforce  /etc/apparmor.d/team-alpha-coord /etc/apparmor.d/team-alpha-worker ;;
  complain) aa-complain /etc/apparmor.d/team-alpha-coord /etc/apparmor.d/team-alpha-worker ;;
  *) echo "install: bad TA_AA_MODE=$AA_MODE" >&2; exit 1 ;;
esac

# ---------- systemd units ----------
echo "install: systemd units"
SD="$HARNESS/scripts/sandbox/systemd"
install -m 0644 "$SD/team-alpha-nats.service"        /etc/systemd/system/team-alpha-nats.service
install -m 0644 "$SD/team-alpha-coord.service"       /etc/systemd/system/team-alpha-coord.service
install -m 0644 "$SD/team-alpha-worker@.service"     /etc/systemd/system/team-alpha-worker@.service

# Drop NATS conf — local only, token-auth.
if [[ ! -f /etc/team-alpha/nats.conf ]]; then
  TOKEN="$(openssl rand -hex 32)"
  install -m 0640 -o root -g team-alpha /dev/null /etc/team-alpha/nats-token
  printf '%s\n' "$TOKEN" > /etc/team-alpha/nats-token
  cat > /etc/team-alpha/nats.conf <<EOF
listen: 127.0.0.1:4222
http: 127.0.0.1:8222
authorization {
  token: "$TOKEN"
}
EOF
  chmod 0640 /etc/team-alpha/nats.conf
  chown root:team-alpha /etc/team-alpha/nats.conf
fi

# Record project path for units.
cat > /etc/team-alpha/env <<EOF
TA_PROJECT=$PROJECT
TA_HARNESS=$HARNESS
EOF
chmod 0644 /etc/team-alpha/env

systemctl daemon-reload
systemctl enable team-alpha-nats.service

echo "install: done. AppArmor mode = $AA_MODE"
aa-status --profiled || true
