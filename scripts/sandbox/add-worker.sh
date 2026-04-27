#!/usr/bin/env bash
# add-worker.sh — provision a per-worker user inside the VM and enable its unit.
#
# Run inside the VM (or via `colima ssh -- sudo bash ...`).
# Idempotent.

set -euo pipefail

NAME="${1:-}"
[[ -n "$NAME" ]] || { echo "usage: add-worker.sh <name>" >&2; exit 1; }
[[ "$NAME" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || {
  echo "add-worker: invalid name (lowercase letters/digits/hyphen, start with letter, ≤31 chars)" >&2
  exit 1
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "add-worker: must run as root" >&2; exit 1
fi

USER_NAME="ta-worker-$NAME"
HOME_DIR="/var/lib/team-alpha/workers/$NAME"
WORK_DIR="/work/workers/$NAME"

if ! id "$USER_NAME" >/dev/null 2>&1; then
  echo "add-worker: creating user $USER_NAME"
  useradd --system --create-home --home-dir "$HOME_DIR" \
          --shell /usr/sbin/nologin --gid team-alpha "$USER_NAME"
fi

install -d -m 0700 -o "$USER_NAME" -g team-alpha "$WORK_DIR"
# Coord needs read access for review. ACL grants per-user, not per-group,
# so peer workers (also in 'team-alpha') still cannot traverse this dir.
setfacl    -m u:ta-coord:rx  "$WORK_DIR"
setfacl -d -m u:ta-coord:rx  "$WORK_DIR"

systemctl daemon-reload
systemctl enable "team-alpha-worker@$NAME.service"

echo "add-worker: $NAME ready."
echo "  user:      $USER_NAME"
echo "  worktree:  $WORK_DIR"
echo "  start:     systemctl start team-alpha-worker@$NAME"
