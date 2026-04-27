#!/usr/bin/env bash
# reload-apparmor.sh — re-parse team-alpha AppArmor profiles in place.
#
# Run inside the VM as root after editing the local override files at
#   /etc/apparmor.d/local/team-alpha-{base,coord,worker}
# without re-running the full install-in-vm.sh.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "reload-apparmor: must run as root" >&2; exit 1
fi

apparmor_parser -r /etc/apparmor.d/team-alpha-coord
apparmor_parser -r /etc/apparmor.d/team-alpha-worker

echo "reload-apparmor: profiles re-parsed."
aa-status | grep -E "^   team-alpha" || true
