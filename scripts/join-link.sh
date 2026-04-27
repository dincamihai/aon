#!/usr/bin/env bash
# scripts/join-link.sh — self-contained joiner bootstrap.
#
# Usage (joiner side, no install needed):
#
#   # Engine repo is private, so the operator's `aon onboard` output
#   # embeds this script inline (gzip + base64). The joiner runs:
#   #
#   #   echo '<b64>' | base64 -d | gunzip | bash -s -- <token> <bits>
#   #
#   # If you have the script locally instead:
#   #   bash scripts/join-link.sh <token> <cloudflared-bits>
#
# What it does:
#   1. Decodes the aon:// token (base64-url JSON).
#   2. Validates expiry.
#   3. Clones the team-aon repo into ~/Repos/<team>-aon (skip if present).
#   4. Writes ~/.team-alpha/<role>.password (chmod 600) from the token.
#   5. Builds the NATS URL from the cloudflared bits arg
#      (wss://<bits>.trycloudflare.com), or accepts a full URL.
#   6. Probes the NATS handshake.
#   7. If `aon` is on PATH: invokes `aon join` to stamp the work-repo.
#      Otherwise prints follow-up instructions (clone engine + pipx install).
#
# Cross-platform: Linux + macOS. Deps: bash, jq, base64, git, curl, nats CLI.
# Optional: python3 (used as fallback for ISO-8601 arithmetic).

set -euo pipefail

# ── pretty output ──────────────────────────────────────────────────
_ok()   { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
_info() { printf '\033[36m▸\033[0m %s\n' "$*" >&2; }
_warn() { printf '\033[33m⚠\033[0m %s\n' "$*" >&2; }
_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
_fail() { _err "$@"; exit 1; }

# ── arg parse ──────────────────────────────────────────────────────
TOKEN="${1:-}"
BITS="${2:-}"
[[ -n "$TOKEN" && -n "$BITS" ]] || {
  cat >&2 <<USAGE
Usage: $(basename "$0") <token> <cloudflared-bits>

  token            aon://... blob from operator's 'aon onboard' output
  cloudflared-bits 4-word random subdomain piece (e.g. transportation-repeated-ppm-bobby)
                   or full URL (wss://..., nats://...)
USAGE
  exit 2
}

[[ "$TOKEN" == aon://* ]] || _fail "token must start with 'aon://'"

# ── prereq check ───────────────────────────────────────────────────
for cmd in jq base64 git curl nats; do
  command -v "$cmd" >/dev/null 2>&1 || _fail "missing prerequisite: $cmd"
done

# ── decode token ───────────────────────────────────────────────────
B64="${TOKEN#aon://}"
B64="$(printf '%s' "$B64" | sed 's|-|+|g; s|_|/|g')"
PAD=$((4 - ${#B64} % 4)); [[ "$PAD" == 4 ]] || B64="$B64$(printf '=%.0s' $(seq 1 $PAD))"
JSON="$(printf '%s' "$B64" | base64 -d 2>/dev/null)" \
  || _fail "token base64 decode failed"

V="$(printf '%s' "$JSON" | jq -r .v)"
TEAM="$(printf '%s' "$JSON" | jq -r .team)"
REPO="$(printf '%s' "$JSON" | jq -r .team_repo_url)"
ROLE="$(printf '%s' "$JSON" | jq -r .role)"
PW="$(printf '%s' "$JSON" | jq -r .password)"
EXP="$(printf '%s' "$JSON" | jq -r .expires_at)"

case "$V" in
  1) _warn "v1 token (deprecated; carries nats_url). Bits arg overrides." ;;
  2) : ;;
  *) _fail "unsupported token version: $V" ;;
esac

# ── expiry check (string-compare on ISO-8601 UTC) ─────────────────
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "$NOW" < "$EXP" ]] || _fail "token expired at $EXP — ask operator to regenerate"

_info "token decoded: team=$TEAM role=$ROLE expires=$EXP"

# ── build NATS URL from bits ──────────────────────────────────────
case "$BITS" in
  wss://*|ws://*|nats://*) NATS_URL="$BITS" ;;
  *) NATS_URL="wss://${BITS}.trycloudflare.com" ;;
esac
_info "nats url: $NATS_URL"

# ── locate / clone team-aon repo ──────────────────────────────────
# Normalize git remotes for comparison: strip trailing .git, rewrite
# git@github.com:owner/repo → https://github.com/owner/repo.
_norm_url() {
  printf '%s' "$1" | sed -E 's|\.git$||; s|^git@github.com:|https://github.com/|; s|/+$||'
}
REPO_NORM="$(_norm_url "$REPO")"

TEAM_DIR=""
# (1) caller is inside a git checkout whose origin matches token's repo? use it.
if CWD_TOP="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  CWD_ORIGIN="$(git -C "$CWD_TOP" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$CWD_ORIGIN" && "$(_norm_url "$CWD_ORIGIN")" == "$REPO_NORM" ]]; then
    TEAM_DIR="$CWD_TOP"
    _ok "running inside matching repo → $TEAM_DIR (skip clone)"
  fi
fi
# (2) fallback: ~/Repos/<team>-aon — reuse if present, else clone.
if [[ -z "$TEAM_DIR" ]]; then
  TEAM_DIR="$HOME/Repos/${TEAM}-aon"
  if [[ -d "$TEAM_DIR/.git" ]]; then
    _ok "team-aon repo present → $TEAM_DIR"
    git -C "$TEAM_DIR" pull --ff-only 2>&1 | tail -2 || _warn "pull non-ff; continuing"
  else
    _info "cloning team-aon repo → $TEAM_DIR"
    mkdir -p "$(dirname "$TEAM_DIR")"
    git clone "$REPO" "$TEAM_DIR" || _fail "clone failed: $REPO"
  fi
fi

# ── place password file ───────────────────────────────────────────
mkdir -p "$HOME/.team-alpha" && chmod 700 "$HOME/.team-alpha"
PWFILE="$HOME/.team-alpha/$ROLE.password"
printf '%s' "$PW" > "$PWFILE"
chmod 600 "$PWFILE"
_ok "creds → $PWFILE (chmod 600)"

# ── handshake probe ───────────────────────────────────────────────
_info "probing $NATS_URL as $ROLE …"
if NATS_PASSWORD="$PW" nats --server "$NATS_URL" --user "$ROLE" --timeout 5s \
     pub "agents.$ROLE.events" "{\"kind\":\"probe\",\"ts\":\"$NOW\"}" \
     >/dev/null 2>&1; then
  _ok "handshake OK"
else
  cat >&2 <<EOF
$(_err "handshake FAILED at $NATS_URL")
  Common causes:
    - cloudflared bits don't match operator's current tunnel
    - operator's NATS not running
    - token's password doesn't match server (token revoked / aged)
  Ask operator to confirm bits and run 'aon doctor'.
EOF
  exit 1
fi

# ── stamp work-repo: prefer aon if installed, else print follow-up ─
if command -v aon >/dev/null 2>&1; then
  _info "found 'aon' on PATH → invoking 'aon join-link' for stamping"
  exec aon join-link "$TOKEN" "$BITS"
fi

# Fallback path: aon not installed — print the next step.
cat >&2 <<EOF

────────────────────────────────────────────────────────────────────
  ✓ Joiner bootstrap complete (handshake green).
────────────────────────────────────────────────────────────────────

To finish stamping a work-repo (where you'll run 'claude'), install
the 'aon' CLI once and re-run join-link:

  # macOS / Linux:
  pipx install git+${REPO%/*}/ai-over-nats
  # if pipx is missing:
  #   Linux:  apt/dnf/pacman install pipx  (or: pip3 install --user pipx)
  #   macOS:  brew install pipx
  # then: pipx ensurepath  &&  exec \$SHELL -l

  aon join-link $TOKEN $BITS

That command stamps <work-repo>/.mcp.json + .claude/settings.json +
CLAUDE.md → role brief, then prints 'cd <work-repo> && claude'.

────────────────────────────────────────────────────────────────────
EOF
