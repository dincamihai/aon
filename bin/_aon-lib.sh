#!/usr/bin/env bash
# _aon-lib.sh — shared helpers for the `aon` CLI.
# Sourced, not executed. No `set -e` here; caller controls.

# ── Constants ──
AON_SCHEMA_VERSION="0.1"

# ── Paths ──
# AON_ENGINE_DIR is the engine repo (where this script lives).
# AON_TEAM_DIR is the per-team repo (caller's CWD on init/doctor/add-role).
# Resolves at source-time so callers can rely on it.
if [[ -z "${AON_ENGINE_DIR:-}" ]]; then
  _aon_self="${BASH_SOURCE[0]}"
  AON_ENGINE_DIR="$(cd -- "$(dirname -- "$_aon_self")/.." && pwd)"
  unset _aon_self
fi
export AON_ENGINE_DIR

# ── Logging ──
aon_info() { printf '%s\n' "$*" >&2; }
aon_ok()   { printf '✓ %s\n' "$*" >&2; }
aon_warn() { printf '⚠ %s\n' "$*" >&2; }
aon_err()  { printf '✗ %s\n' "$*" >&2; }
aon_fail() { aon_err "$*"; exit 1; }

# ── TOML parser (subset) ──
# No external dep. Handles: top-level scalar values inside [section] +
# repeated [[section]] arrays-of-tables. Strings in double quotes.
# Lists inside [...] of strings only. Comments after #.
#
# Usage:
#   aon_toml_get FILE SECTION KEY
#     → echoes the value (string scalars only). Empty if absent.
#   aon_toml_get_list FILE SECTION KEY
#     → echoes whitespace-separated items.
#   aon_toml_array_count FILE TABLE
#     → echoes count of [[TABLE]] entries.
#   aon_toml_array_get FILE TABLE INDEX KEY
#     → echoes the value of KEY in the INDEX-th [[TABLE]] (0-based).

aon_toml_get() {
  local file="$1" section="$2" key="$3"
  awk -v s="[$section]" -v k="$key" '
    BEGIN{ insec=0 }
    /^\s*#/ { next }
    /^\s*$/ { next }
    /^\[\[/ { insec=0; next }
    /^\[/   { insec = ($0 == s); next }
    insec {
      sub(/[[:space:]]*#.*$/, "")           # strip trailing comment
      if (match($0, "^[[:space:]]*" k "[[:space:]]*=[[:space:]]*")) {
        v = substr($0, RSTART + RLENGTH)
        gsub(/^"|"$/, "", v)
        print v; exit
      }
    }
  ' "$file"
}

aon_toml_get_list() {
  local file="$1" section="$2" key="$3"
  awk -v s="[$section]" -v k="$key" '
    BEGIN{ insec=0 }
    /^\s*#/ { next }
    /^\s*$/ { next }
    /^\[\[/ { insec=0; next }
    /^\[/   { insec = ($0 == s); next }
    insec {
      sub(/[[:space:]]*#.*$/, "")
      if (match($0, "^[[:space:]]*" k "[[:space:]]*=[[:space:]]*\\[")) {
        v = substr($0, RSTART + RLENGTH)
        sub(/\][[:space:]]*$/, "", v)
        gsub(/[",]/, " ", v)
        gsub(/[[:space:]]+/, " ", v)
        print v; exit
      }
    }
  ' "$file"
}

aon_toml_array_count() {
  local file="$1" table="$2"
  grep -c "^\[\[$table\]\]" "$file" 2>/dev/null || echo 0
}

aon_toml_array_get() {
  local file="$1" table="$2" idx="$3" key="$4"
  awk -v t="[[$table]]" -v want="$idx" -v k="$key" '
    BEGIN{ cur=-1 }
    /^\s*#/ { next }
    /^\[\[/ {
      if ($0 == t) { cur++ }
      next
    }
    /^\[/   { next }
    cur == want {
      sub(/[[:space:]]*#.*$/, "")
      if (match($0, "^[[:space:]]*" k "[[:space:]]*=[[:space:]]*")) {
        v = substr($0, RSTART + RLENGTH)
        gsub(/^"|"$/, "", v)
        print v; exit
      }
    }
  ' "$file"
}

# ── Config loader ──
# Resolves the per-team aon.toml; falls back to defaults when absent.
# Sets AON_* globals callers can read.
aon_load_config() {
  AON_TEAM_DIR="${AON_TEAM_DIR:-$PWD}"
  AON_TOML="$AON_TEAM_DIR/aon.toml"

  # Refuse to run team-mutating commands from inside the engine repo —
  # easy mistake (cwd left in ai-over-nats) that pollutes engine paths
  # with rendered artifacts. The marker file is committed at engine
  # root by the maintainers.
  if [[ -f "$AON_TEAM_DIR/.aon-engine" ]]; then
    cat >&2 <<EOF
✗ aon: refusing to operate from the engine repo ($AON_TEAM_DIR).

  This directory is the ai-over-nats engine itself, not a per-team
  repo. Running team-mutating commands here would pollute the engine
  with rendered prompts, auth.conf, and other team state.

  Fix:  cd to your team-aon repo first.
        aon commands resolve aon.toml from \$PWD (or AON_TEAM_DIR).

EOF
    exit 2
  fi

  if [[ -r "$AON_TOML" ]]; then
    AON_TOML_PRESENT=1
    AON_SCHEMA="$(aon_toml_get "$AON_TOML" engine version)"
    AON_TEAM_NAME="$(aon_toml_get "$AON_TOML" team name)"
    AON_TEAM_ACCOUNT="$(aon_toml_get "$AON_TOML" team account)"
    AON_TEAM_KV="$(aon_toml_get "$AON_TOML" team kv_bucket)"
    AON_NATS_URL="$(aon_toml_get "$AON_TOML" nats url)"
    AON_NATS_WS_URL="$(aon_toml_get "$AON_TOML" nats ws_url)"
    AON_NATS_ADMIN="$(aon_toml_get "$AON_TOML" nats admin_user)"
    AON_TASK_DIR="$(aon_toml_get "$AON_TOML" paths task_dir)"
    AON_PROMPTS_DIR="$(aon_toml_get "$AON_TOML" paths prompts_dir)"
    AON_AGENTS_DIR="$(aon_toml_get "$AON_TOML" paths agents_dir)"
    AON_HOOKS_DIR="$(aon_toml_get "$AON_TOML" paths hooks_dir)"
  else
    AON_TOML_PRESENT=0
    AON_SCHEMA="$AON_SCHEMA_VERSION"
    AON_TEAM_NAME="$(basename "$AON_TEAM_DIR")"
    AON_TEAM_ACCOUNT="$AON_TEAM_NAME"
    AON_TEAM_KV="${AON_TEAM_NAME%-aon}-state"
    AON_NATS_URL="nats://localhost:4222"
    AON_NATS_WS_URL=""
    AON_NATS_ADMIN="sysadmin"
    AON_TASK_DIR=".tasks"
    AON_PROMPTS_DIR="agent-prompts"
    AON_AGENTS_DIR="agents"
    AON_HOOKS_DIR="hooks"
  fi

  # Schema version check.
  if [[ "$AON_TOML_PRESENT" -eq 1 && -n "$AON_SCHEMA" && "$AON_SCHEMA" != "$AON_SCHEMA_VERSION" ]]; then
    aon_warn "aon.toml schema=$AON_SCHEMA, this engine speaks $AON_SCHEMA_VERSION"
  fi

  AON_ROLES_COUNT="$(aon_toml_array_count "$AON_TOML" roles 2>/dev/null || echo 0)"
}

# ── ~/.aon/ registry ──
# The registry decouples team state from the operator's cwd. Layout:
#
#   ~/.aon/
#     work-repos.json            # [{path, team, role}, ...]
#     teams/<team>/
#       repo/                    # team-aon checkout
#       creds/<role>.{password,env}
#
# Functions below:
#   _aon_registry_root            → ~/.aon
#   _aon_team_repo_dir TEAM       → ~/.aon/teams/<team>/repo
#   _aon_team_creds_dir TEAM      → ~/.aon/teams/<team>/creds
#   _aon_work_repos_json          → ~/.aon/work-repos.json
#   _aon_register_work_repo PATH TEAM ROLE
#   _aon_resolve_from_cwd [DIR]   echoes "TEAM<TAB>ROLE<TAB>PATH" or rc=1

_aon_registry_root() { printf '%s/.aon' "$HOME"; }
_aon_team_repo_dir()  { printf '%s/.aon/teams/%s/repo' "$HOME" "$1"; }
_aon_team_creds_dir() { printf '%s/.aon/teams/%s/creds' "$HOME" "$1"; }
_aon_work_repos_json() { printf '%s/.aon/work-repos.json' "$HOME"; }

_aon_realpath() {
  # Cross-platform realpath (BSD/macOS lacks `realpath` by default; use
  # python3 since it's already a hard dep).
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

_aon_register_work_repo() {
  local path="$1" team="$2" role="$3"
  [[ -n "$path" && -n "$team" && -n "$role" ]] || {
    aon_err "_aon_register_work_repo: need PATH TEAM ROLE"
    return 2
  }
  path="$(_aon_realpath "$path")"
  local f; f="$(_aon_work_repos_json)"
  mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || printf '[]\n' > "$f"
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  jq --arg path "$path" --arg team "$team" --arg role "$role" \
    '[.[] | select(.path != $path)] + [{path:$path, team:$team, role:$role}]' \
    "$f" > "$tmp" && mv "$tmp" "$f"
}

_aon_resolve_from_cwd() {
  # Walk from cwd (or arg) up to fs root, return first match.
  # Outputs "TEAM<TAB>ROLE<TAB>ABS_PATH" on stdout. rc=1 if no match.
  local start="${1:-$PWD}"
  local f; f="$(_aon_work_repos_json)"
  [[ -f "$f" ]] || return 1
  local cwd; cwd="$(_aon_realpath "$start")"
  python3 - "$f" "$cwd" <<'PY'
import json, sys, pathlib
reg, cwd = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
try:
    entries = json.load(open(reg))
except Exception:
    sys.exit(1)
candidates = [cwd, *cwd.parents]
for e in entries:
    if not isinstance(e, dict): continue
    p = pathlib.Path(e.get("path","")).resolve()
    if p in candidates:
        print(f"{e['team']}\t{e['role']}\t{p}")
        sys.exit(0)
sys.exit(1)
PY
}

# ── Render helper ──
# Sed-based template renderer. Inputs: src, dst, then KEY=VAL pairs.
# Replaces @KEY@ with VAL in src → dst. Idempotent.
aon_render() {
  local src="$1" dst="$2"; shift 2
  local args=()
  while [[ $# -gt 0 ]]; do
    local kv="$1"; shift
    local k="${kv%%=*}" v="${kv#*=}"
    args+=( -e "s|@${k}@|${v}|g" )
  done
  mkdir -p "$(dirname "$dst")"
  sed "${args[@]}" "$src" > "$dst"
}
