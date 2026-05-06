#!/usr/bin/env bash
# Regression for `cmd_resolve_env` newline-stripping bug.
#
# Pre-fix: _ce_out built via repeated `_ce_out+="$(printf ...)"` calls.
# $() strips trailing newlines, so lines concatenated without separators:
#   export AON_ROLE=sunexport AON_ROLE_KIND=manager...
# eval then set AON_ROLE=sunexport instead of sun.
#
# Fix: single printf call with all \n inside the format string.
# Internal \n are preserved; only the final trailing \n is stripped (harmless).
#
# Cases:
#   1. Each output line is a separate `export VAR=value` — no concatenation
#   2. AON_ROLE contains only the role name, not role+next-word
#   3. eval of output sets each var independently

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AON="$HERE/../../bin/aon"
[[ -x "$AON" ]] || { echo "✗ cannot find bin/aon at $AON" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── fixture: minimal team setup ──
# _aon_team_repo_dir "workers" → $HOME/.aon/teams/workers/repo
TEAM_REPO_DIR="$WORK/.aon/teams/workers/repo"
CREDS_DIR="$WORK/.aon/teams/workers/creds"
WORK_REPO="$WORK/myproject"
mkdir -p "$TEAM_REPO_DIR" "$CREDS_DIR" "$WORK_REPO"

cat > "$TEAM_REPO_DIR/aon.toml" <<'TOML'
[engine]
version = "0.1"

[team]
name      = "workers"
kv_bucket = "workers-state"

[nats]
url = "nats://localhost:4222"

[[roles]]
name   = "sun"
kind   = "manager"
domain = "fullstack"
TOML

# Fake creds file (content irrelevant for resolve-env output)
touch "$CREDS_DIR/sun.creds"

# work-repos registry — maps WORK_REPO path → role
cat > "$WORK/.aon/work-repos.json" <<JSON
[{"team":"workers","role":"sun","path":"$WORK_REPO"}]
JSON

# ── run resolve-env from WORK_REPO so registry lookup matches ──
out="$(
  cd "$WORK_REPO" && \
  env -i \
    HOME="$WORK" \
    PATH="$PATH" \
    AON_ROLE=sun \
    AON_NATS_URL=nats://localhost:4222 \
    AON_TEAM_DIR="$TEAM_REPO_DIR" \
    bash "$AON" resolve-env 2>/dev/null
)"

[[ -n "$out" ]] || fail "resolve-env produced no output (registry lookup failed?)"

# 1. Each non-empty line must start with `export ` — no concatenated lines
bad_lines="$(printf '%s\n' "$out" | grep -v '^export ' | grep -v '^[[:space:]]*$' || true)"
[[ -z "$bad_lines" ]] || fail "non-export lines in output (concatenation?): $bad_lines"
ok "all output lines start with 'export '"

# 2. AON_ROLE line must be exactly `export AON_ROLE=<word>` — no suffix
role_line="$(printf '%s\n' "$out" | grep '^export AON_ROLE=')"
[[ -n "$role_line" ]] || fail "AON_ROLE not found in output"
role_val="${role_line#export AON_ROLE=}"
# Must be a single word (no space, no extra 'export' concatenated)
[[ "$role_val" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "AON_ROLE value malformed: '$role_val' (expected single word)"
[[ "$role_val" == "sun" ]] || fail "AON_ROLE wrong value: '$role_val' (expected 'sun')"
ok "AON_ROLE=sun (no concatenation)"

# 3. eval sets vars independently
eval "$out" 2>/dev/null
[[ "${AON_ROLE:-}" == "sun" ]]         || fail "eval: AON_ROLE='${AON_ROLE:-}' expected 'sun'"
[[ "${AON_ROLE_KIND:-}" == "manager" ]] || fail "eval: AON_ROLE_KIND='${AON_ROLE_KIND:-}' expected 'manager'"
[[ "${AON_TEAM:-}" == "workers" ]]     || fail "eval: AON_TEAM='${AON_TEAM:-}' expected 'workers'"
ok "eval sets AON_ROLE, AON_ROLE_KIND, AON_TEAM independently"

ok "ALL OK"
