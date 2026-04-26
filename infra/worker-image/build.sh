#!/usr/bin/env bash
# Build team-alpha worker images. Tags both `:<short-sha>` and
# `:latest` so compose can pin reproducibly while spawn scripts use
# `:latest` for convenience.
#
# Usage:
#   build.sh                 # build base + every Dockerfile.<role>
#   build.sh base            # build base only
#   build.sh priya raj ...   # build base then named role overlays
#
# Container runtime auto-detected (docker | podman). Override with
# `CTR=podman build.sh`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CTR="${CTR:-}"
if [ -z "$CTR" ]; then
  if command -v docker >/dev/null 2>&1; then
    CTR=docker
  elif command -v podman >/dev/null 2>&1; then
    CTR=podman
  else
    echo "ERROR: neither docker nor podman on PATH" >&2
    exit 2
  fi
fi
echo "▸ runtime: $CTR"

SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
echo "▸ tag suffix: $SHA"

# Match image arch to the *runtime VM* arch (not host). On Apple
# Silicon w/ colima default (x86_64 VM), forcing --platform=linux/arm64
# fails with "exec format error". Detect from docker info.
PLATFORM="${PLATFORM:-}"
if [ -z "$PLATFORM" ]; then
  srv_arch="$("$CTR" version --format '{{.Server.Arch}}' 2>/dev/null || echo "")"
  case "$srv_arch" in
    arm64|aarch64) PLATFORM=linux/arm64 ;;
    amd64|x86_64)  PLATFORM=linux/amd64 ;;
    *)             PLATFORM="" ;;
  esac
fi
[ -n "$PLATFORM" ] && echo "▸ platform: $PLATFORM"
PLATFORM_FLAG=()
[ -n "$PLATFORM" ] && PLATFORM_FLAG=(--platform "$PLATFORM")

build_base() {
  echo "▸ building team-alpha-worker-base:$SHA"
  # Narrow build context: stage Dockerfile.base + mcp-server in a
  # temp dir so the worker image cache invalidates on mcp-server
  # changes only, not every repo-root edit.
  local staging
  staging="$(mktemp -d -t team-alpha-base.XXXXXX)"
  trap "rm -rf '$staging'" RETURN
  cp "$SCRIPT_DIR/Dockerfile.base" "$staging/Dockerfile"
  cp -R "$REPO_ROOT/mcp-server" "$staging/mcp-server"
  # Drop common build artifacts that don't belong in the image.
  find "$staging/mcp-server" \
       \( -name __pycache__ -o -name '*.egg-info' -o -name dist -o -name build -o -name .pytest_cache \) \
       -prune -exec rm -rf {} + 2>/dev/null || true
  "$CTR" build "${PLATFORM_FLAG[@]}" \
    -f "$staging/Dockerfile" \
    -t "team-alpha-worker-base:$SHA" \
    -t "team-alpha-worker-base:latest" \
    "$staging"
}

build_role() {
  local role="$1"
  local dockerfile="$SCRIPT_DIR/Dockerfile.$role"
  if [ ! -f "$dockerfile" ]; then
    echo "▸ skip $role (no $dockerfile)"
    return 0
  fi
  echo "▸ building team-alpha-worker-$role:$SHA"
  "$CTR" build "${PLATFORM_FLAG[@]}" \
    -f "$dockerfile" \
    --build-arg "BASE_IMAGE=team-alpha-worker-base:$SHA" \
    -t "team-alpha-worker-$role:$SHA" \
    -t "team-alpha-worker-$role:latest" \
    "$SCRIPT_DIR"
}

if [ "$#" -eq 0 ]; then
  build_base
  for f in "$SCRIPT_DIR"/Dockerfile.*; do
    case "$f" in
      *Dockerfile.base) continue ;;
    esac
    role="${f##*/Dockerfile.}"
    build_role "$role"
  done
elif [ "$1" = "base" ] && [ "$#" -eq 1 ]; then
  build_base
else
  build_base
  for role in "$@"; do
    build_role "$role"
  done
fi

echo "▸ done."
