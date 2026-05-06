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
EXTERNAL_NATS=""
SLACK_EVENTS_DIR=""
AA_MODE="${TA_AA_MODE:-enforce}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --local-apparmor) LOCAL_APPARMOR="$2"; shift 2 ;;
    --aa-mode) AA_MODE="$2"; shift 2 ;;
    --external-nats) EXTERNAL_NATS="$2"; shift 2 ;;
    --slack-events-dir) SLACK_EVENTS_DIR="$2"; shift 2 ;;
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
  ca-certificates curl git jq nftables unzip \
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
install -m 0644 "$SD/team-alpha-coord.service"            /etc/systemd/system/team-alpha-coord.service
install -m 0644 "$SD/team-alpha-worker@.service"         /etc/systemd/system/team-alpha-worker@.service
install -m 0644 "$SD/team-alpha-slack-bridge@.service"   /etc/systemd/system/team-alpha-slack-bridge@.service

if [[ -z "$EXTERNAL_NATS" ]]; then
  # In-VM broker — original docs/sandbox.md design.
  install -m 0644 "$SD/team-alpha-nats.service"      /etc/systemd/system/team-alpha-nats.service
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
  EFFECTIVE_NATS_URL="nats://127.0.0.1:4222"
else
  # External broker (host's nats-server, reached via host.lima.internal).
  # Skip in-VM nats unit. Coord/worker units depend on it via
  # Requires=team-alpha-nats.service; mask the unit so the dependency
  # is satisfied as a no-op.
  systemctl disable team-alpha-nats.service 2>/dev/null || true
  systemctl mask team-alpha-nats.service 2>/dev/null || true
  EFFECTIVE_NATS_URL="$EXTERNAL_NATS"
  echo "install: external NATS — skipping in-VM broker (url=$EXTERNAL_NATS)"
fi

# Record project + nats url + optional slack events dir for units.
cat > /etc/team-alpha/env <<EOF
TA_PROJECT=$PROJECT
TA_HARNESS=$HARNESS
TA_NATS_URL=$EFFECTIVE_NATS_URL
AON_NATS_URL=$EFFECTIVE_NATS_URL
EOF
[[ -n "$SLACK_EVENTS_DIR" ]] && echo "TA_SLACK_EVENTS_DIR=$SLACK_EVENTS_DIR" >> /etc/team-alpha/env
chmod 0644 /etc/team-alpha/env

# Bypass marker dir — agent denied write per AppArmor profile, root
# (or operator via 'colima ssh') flips it on/off.
install -d -m 0755 -o root -g root /etc/team-alpha
# (note: /etc/team-alpha already created above; this is idempotent.)

systemctl daemon-reload
[[ -z "$EXTERNAL_NATS" ]] && systemctl enable team-alpha-nats.service

# Slack bridge: enable for roles listed in TA_SLACK_BRIDGE_ROLES (default: sun).
# Only wired if TA_SLACK_EVENTS_DIR is set — otherwise bridge can't find events.jsonl.
if [[ -n "$SLACK_EVENTS_DIR" ]]; then
  SLACK_BRIDGE_ROLES="${TA_SLACK_BRIDGE_ROLES:-sun}"
  for _sbr in $SLACK_BRIDGE_ROLES; do
    systemctl enable "team-alpha-slack-bridge@${_sbr}.service"
    echo "install: slack-bridge enabled for role=${_sbr}"
  done
fi

# ---------- nats CLI + aon engine ----------
# Agent hooks (cmd-gate, etc.) and `aon` itself shell out to `nats`.
# apt's `nats-server` package only ships the server. Install client.
if ! command -v nats >/dev/null 2>&1; then
  echo "install: nats CLI"
  arch="$(uname -m)"; case "$arch" in
    aarch64|arm64) NATS_ARCH=arm64 ;;
    x86_64|amd64)  NATS_ARCH=amd64 ;;
    *) echo "warn: unknown arch $arch — skipping nats CLI" >&2; NATS_ARCH="" ;;
  esac
  if [[ -n "$NATS_ARCH" ]]; then
    NATS_VER="0.1.5"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/nats-io/natscli/releases/download/v${NATS_VER}/nats-${NATS_VER}-linux-${NATS_ARCH}.zip" \
      -o "$tmp/nats.zip"
    (cd "$tmp" && unzip -q nats.zip)
    install -m 0755 "$tmp/nats-${NATS_VER}-linux-${NATS_ARCH}/nats" /usr/local/bin/nats
    rm -rf "$tmp"
  fi
fi

# uv / uvx — used by MCP servers shipped as Python packages
# (e.g. slack-mcp invoked as `uvx --from /path slack-mcp`).
if ! command -v uvx >/dev/null 2>&1; then
  echo "install: uv/uvx"
  arch="$(uname -m)"; case "$arch" in
    aarch64|arm64) UV_ARCH=aarch64 ;;
    x86_64|amd64)  UV_ARCH=x86_64 ;;
    *) UV_ARCH="" ;;
  esac
  if [[ -n "$UV_ARCH" ]]; then
    UV_VER="0.5.11"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${UV_ARCH}-unknown-linux-gnu.tar.gz" \
      -o "$tmp/uv.tgz"
    tar -xzf "$tmp/uv.tgz" -C "$tmp"
    install -m 0755 "$tmp/uv-${UV_ARCH}-unknown-linux-gnu/uv"  /usr/local/bin/uv
    install -m 0755 "$tmp/uv-${UV_ARCH}-unknown-linux-gnu/uvx" /usr/local/bin/uvx
    rm -rf "$tmp"
  fi
fi

# Wrapper for host-mounted `aon` engine. Symlink would break aon's
# internal `_aon_dir=$(dirname BASH_SOURCE)` resolution; exec from a
# wrapper preserves the real path.
cat > /usr/local/bin/aon <<EOF
#!/usr/bin/env bash
exec $HARNESS/bin/aon "\$@"
EOF
chmod 0755 /usr/local/bin/aon
echo "install: aon wrapper → /usr/local/bin/aon (exec $HARNESS/bin/aon)"

# aon-mcp Linux venv. Host's mcp-server/.venv is macOS-built; we mount
# it RO and can't reuse. Copy src into a writable VM path, create a
# Linux venv with uv, install the package, expose binary on PATH.
if command -v uv >/dev/null 2>&1 && [[ -d "$HARNESS/mcp-server" ]]; then
  echo "install: aon-mcp Linux venv"
  install -d -m 0755 /opt/aon-mcp /opt/aon-mcp/src
  cp -a "$HARNESS/mcp-server/." /opt/aon-mcp/src/
  for stale in /opt/aon-mcp/src/.venv /opt/aon-mcp/src/build /opt/aon-mcp/src/src/aon_mcp.egg-info; do
    [[ -e "$stale" ]] && find "$stale" -delete
  done
  uv venv /opt/aon-mcp/venv >/dev/null
  uv pip install --quiet --python /opt/aon-mcp/venv/bin/python /opt/aon-mcp/src
  ln -sf /opt/aon-mcp/venv/bin/aon-mcp /usr/local/bin/aon-mcp
fi

# board-tui Linux venv. Source: look next to harness (sibling repo).
# Fallback to git clone if not present.
BOARD_TUI_SRC="${BOARD_TUI_SRC:-$(dirname "$HARNESS")/board-tui}"
if command -v uv >/dev/null 2>&1; then
  if [[ -d "$BOARD_TUI_SRC" ]]; then
    echo "install: board-tui Linux venv (from $BOARD_TUI_SRC)"
    install -d -m 0755 /opt/board-tui /opt/board-tui/src
    cp -a "$BOARD_TUI_SRC/." /opt/board-tui/src/
    for stale in /opt/board-tui/src/.venv /opt/board-tui/src/build; do
      [[ -e "$stale" ]] && find "$stale" -delete
    done
    uv venv /opt/board-tui/venv >/dev/null
    uv pip install --quiet --python /opt/board-tui/venv/bin/python /opt/board-tui/src
    ln -sf /opt/board-tui/venv/bin/board-tui-mcp /usr/local/bin/board-tui-mcp
  else
    echo "install: board-tui source not found at $BOARD_TUI_SRC — skipping (set BOARD_TUI_SRC to override)"
  fi
fi

echo "install: done. AppArmor mode = $AA_MODE"
aa-status --profiled || true
