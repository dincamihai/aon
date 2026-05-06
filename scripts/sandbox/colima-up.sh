#!/usr/bin/env bash
# colima-up.sh — bring up the team-alpha sandbox VM.
#
# Idempotent: re-running while the VM is up is a no-op.
# Arch-aware: vz on Apple Silicon (macOS 13+), qemu fallback otherwise.
#
# Env overrides:
#   TA_PROFILE        colima profile name        (default: team-alpha)
#   TA_CPU            vCPUs                      (default: 4)
#   TA_MEMORY         GB RAM                     (default: 8)
#   TA_DISK           GB disk                    (default: 40)
#   TA_HARNESS        ai-over-nats path on host  (default: dir of this script's repo)
#   TA_PROJECT        single project path        (default: unset)
#   TA_REPOS          repos root, mounted ro     (default: $HOME/Repos if it exists)
#                     set to "" to disable.
#   TA_LOCAL_APPARMOR personal AppArmor overrides directory on the host
#                     (default: $HOME/.team-alpha/apparmor if it exists)
#                     contents synced into VM at /etc/apparmor.d/local/team-alpha-{base,coord,worker}
#   TA_AA_MODE        enforce|complain           (default: enforce)
#
# Multi-repo (recommended): leave TA_PROJECT unset, let TA_REPOS mount
# the whole repos tree read-only. Workers clone locally inside the VM.
# Single-repo (legacy): set TA_PROJECT, leave TA_REPOS unset.

set -euo pipefail

TA_PROFILE="${TA_PROFILE:-team-alpha}"
TA_CPU="${TA_CPU:-4}"
TA_MEMORY="${TA_MEMORY:-8}"
TA_DISK="${TA_DISK:-40}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DEFAULT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TA_HARNESS="${TA_HARNESS:-$HARNESS_DEFAULT}"

# Default: mount ~/Repos ro (multi-repo). User can override or disable.
if [[ -z "${TA_REPOS+x}" ]]; then
  if [[ -d "$HOME/Repos" ]]; then
    TA_REPOS="$HOME/Repos"
  else
    TA_REPOS=""
  fi
fi
TA_PROJECT="${TA_PROJECT:-}"

# aon-board state (RW). Default: ~/aon-board if it exists.
if [[ -z "${TA_AON_BOARD+x}" ]]; then
  if [[ -d "$HOME/aon-board" ]]; then
    TA_AON_BOARD="$HOME/aon-board"
  else
    TA_AON_BOARD=""
  fi
fi

if [[ -z "${TA_LOCAL_APPARMOR+x}" ]]; then
  if [[ -d "$HOME/.team-alpha/apparmor" ]]; then
    TA_LOCAL_APPARMOR="$HOME/.team-alpha/apparmor"
  else
    TA_LOCAL_APPARMOR=""
  fi
fi

if [[ ! -d "$TA_HARNESS" ]]; then
  echo "team-alpha: TA_HARNESS not a directory: $TA_HARNESS" >&2
  exit 1
fi
if [[ -n "$TA_PROJECT" && ! -d "$TA_PROJECT" ]]; then
  echo "team-alpha: TA_PROJECT not a directory: $TA_PROJECT" >&2
  exit 1
fi
if [[ -n "$TA_REPOS" && ! -d "$TA_REPOS" ]]; then
  echo "team-alpha: TA_REPOS not a directory: $TA_REPOS" >&2
  exit 1
fi

command -v colima >/dev/null || { echo "team-alpha: colima not on PATH" >&2; exit 1; }

HOST_ARCH="$(uname -m)"
HOST_OS="$(uname -s)"

VM_TYPE="qemu"
COLIMA_ARCH="$HOST_ARCH"
case "$HOST_ARCH" in
  arm64|aarch64) COLIMA_ARCH="aarch64" ;;
  x86_64|amd64)  COLIMA_ARCH="x86_64"  ;;
esac

# Apple Virtualization.framework only on Apple Silicon macOS 13+.
if [[ "$HOST_OS" == "Darwin" ]]; then
  PRODUCT_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  MAJOR="${PRODUCT_VERSION%%.*}"
  if [[ "$HOST_ARCH" == "arm64" && "${MAJOR:-0}" -ge 13 ]]; then
    VM_TYPE="vz"
  fi
fi

# Build mount list. Dedupe overlapping mounts (colima/lima reject nested
# or duplicate paths). Order of precedence: harness (ro), repos (ro),
# project (rw, optional / legacy).
declare -a MOUNT_SPECS=()
[[ -n "$TA_HARNESS"        ]] && MOUNT_SPECS+=( "${TA_HARNESS%/}:r" )
[[ -n "$TA_REPOS"          ]] && MOUNT_SPECS+=( "${TA_REPOS%/}:r"   )
[[ -n "$TA_PROJECT"        ]] && MOUNT_SPECS+=( "${TA_PROJECT%/}:w" )
[[ -n "$TA_AON_BOARD"      ]] && MOUNT_SPECS+=( "${TA_AON_BOARD%/}:w" )
[[ -n "$TA_LOCAL_APPARMOR" ]] && MOUNT_SPECS+=( "${TA_LOCAL_APPARMOR%/}:r" )

dedupe_mounts() {
  local -a out=()
  local s p path mode covered
  for s in "${MOUNT_SPECS[@]}"; do
    path="${s%:*}"; mode="${s##*:}"
    covered=0
    for ((i=0; i<${#out[@]}; i++)); do
      local op="${out[i]%:*}"
      if [[ "$path" == "$op" ]]; then
        # identical path: keep wider mode
        [[ "$mode" == "w" ]] && out[i]="${path}:w"
        covered=1; break
      elif [[ "$path" == "$op"/* ]]; then
        # path is inside an existing mount → drop
        covered=1; break
      elif [[ "$op" == "$path"/* ]]; then
        # existing mount is inside path → replace
        out[i]="${path}:${mode}"
        covered=1; break
      fi
    done
    [[ $covered -eq 0 ]] && out+=( "${path}:${mode}" )
  done
  MOUNT_SPECS=( "${out[@]}" )
}
dedupe_mounts

MOUNTS=()
for s in "${MOUNT_SPECS[@]}"; do MOUNTS+=( "--mount" "$s" ); done

if colima status --profile "$TA_PROFILE" >/dev/null 2>&1; then
  echo "team-alpha: VM '$TA_PROFILE' already running — skipping start"
else
  echo "team-alpha: starting VM profile=$TA_PROFILE arch=$COLIMA_ARCH vm-type=$VM_TYPE"
  echo "team-alpha: mounts: ${MOUNTS[*]}"
  colima start \
    --profile "$TA_PROFILE" \
    --arch "$COLIMA_ARCH" \
    --vm-type "$VM_TYPE" \
    --cpu "$TA_CPU" \
    --memory "$TA_MEMORY" \
    --disk "$TA_DISK" \
    --mount-type virtiofs \
    "${MOUNTS[@]}"
fi

echo "team-alpha: VM up. Running in-VM provisioner."
INSTALL_ARGS=( --harness "$TA_HARNESS" --project "${TA_PROJECT:-$TA_REPOS}" )
[[ -n "$TA_LOCAL_APPARMOR" ]] && INSTALL_ARGS+=( --local-apparmor "$TA_LOCAL_APPARMOR" )
[[ -n "${TA_AA_MODE:-}"    ]] && INSTALL_ARGS+=( --aa-mode "$TA_AA_MODE" )
# External NATS — agent in VM connects to host's broker via
# host.lima.internal. Keeps sysadmin.creds outside the VM (the trust
# boundary). Set TA_EXTERNAL_NATS=auto to use the standard host URL.
if [[ -n "${TA_EXTERNAL_NATS:-}" ]]; then
  if [[ "$TA_EXTERNAL_NATS" == "auto" ]]; then
    TA_EXTERNAL_NATS="nats://host.lima.internal:4222"
  fi
  INSTALL_ARGS+=( --external-nats "$TA_EXTERNAL_NATS" )
  echo "team-alpha: external NATS = $TA_EXTERNAL_NATS"
fi
colima ssh --profile "$TA_PROFILE" -- \
  sudo bash "${TA_HARNESS}/scripts/sandbox/install-in-vm.sh" "${INSTALL_ARGS[@]}"

cat <<EOF

team-alpha: sandbox ready.

  Profile:    $TA_PROFILE
  Arch:       $COLIMA_ARCH
  VM type:    $VM_TYPE
  Harness:    $TA_HARNESS  (ro)
  Repos:      ${TA_REPOS:-(none)}  (ro, multi-repo source)
  Project:    ${TA_PROJECT:-(none)}  (rw, single-repo legacy)

Next:
  colima ssh --profile $TA_PROFILE                            # shell into VM
  bash $TA_HARNESS/scripts/sandbox/add-worker.sh raj          # add a worker
  sudo systemctl start team-alpha-coord                       # start coord (in VM)
  sudo systemctl start team-alpha-worker@raj                  # start worker (in VM)
EOF
