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

# ── Container runtime ──
# AON_CONTAINER_CMD overrides the container-runtime binary (default docker).
# AON_COMPOSE_CMD overrides the compose command (default docker compose).
# Set these persistently when the host uses podman instead of docker.
: "${AON_CONTAINER_CMD:=docker}"
: "${AON_COMPOSE_CMD:=docker compose}"
export AON_CONTAINER_CMD AON_COMPOSE_CMD

# ── Logging ──
aon_info() { printf '%s\n' "$*" >&2; }
aon_ok()   { printf '✓ %s\n' "$*" >&2; }
aon_warn() { printf '⚠ %s\n' "$*" >&2; }
aon_err()  { printf '✗ %s\n' "$*" >&2; }
aon_fail() { aon_err "$*"; exit 1; }

# Hard-fail if $AON_TEAM_DIR is not the toplevel of a git work-tree.
# Without this guard, `git -C "$AON_TEAM_DIR" ...` walks up the parent
# chain (git's default discovery) and silently operates on whatever
# .git it hits first — typically $HOME/.git on operator boxes (dotfiles
# repo, accidental `git init` from years ago). `git add -A` then tries
# to stage the entire home directory. Bad outcome.
#
# Implementation: ask git for the work-tree root and confirm it equals
# $AON_TEAM_DIR. Catches absence (rev-parse fails), walk-up (root !=
# AON_TEAM_DIR), and accepts both regular checkouts and linked
# worktrees (where .git is a gitlink file, not a dir).
#
# Call this at the top of any function that runs git -C "$AON_TEAM_DIR".
# Read-only callers (status, remote get-url) also use it — walk-up still
# happens on reads.
# Returns 0 iff $AON_TEAM_DIR is the toplevel of a git work-tree
# (regular checkout OR linked worktree). Quiet — no stderr. Used by
# `_aon_require_team_git` (hard-fail) and as a predicate in cmd_init /
# cmd_doctor.
_aon_team_is_git_root() {
  local _top _want
  _top="$(git -C "$AON_TEAM_DIR" rev-parse --show-toplevel 2>/dev/null)" || return 1
  # Resolve symlinks on both sides so /var vs /private/var (macOS) or
  # other realpath quirks don't false-fail.
  _top="$(cd -- "$_top" && pwd -P 2>/dev/null)" || return 1
  _want="$(cd -- "$AON_TEAM_DIR" && pwd -P 2>/dev/null)" || return 1
  [[ "$_top" == "$_want" ]]
}

_aon_require_team_git() {
  if ! _aon_team_is_git_root; then
    aon_err "team-aon repo at $AON_TEAM_DIR is not a git work-tree root"
    aon_err "  refusing git operations to avoid walking up to \$HOME/.git"
    aon_err "  fix: git -C '$AON_TEAM_DIR' init  (or re-run 'aon init' — auto-inits)"
    exit 1
  fi
}

# Push the team-aon repo. Captures git's real exit code (no pipe loss)
# and surfaces stderr verbatim on failure so the operator sees the
# actual reason — `fatal: No configured push destination`, auth errors,
# non-FF rejection, hook rejection, all flow through here. Returns
# git's exit code; caller decides hard-fail vs warn.
#
# Don't pipe through `tail | grep` — it (a) only sees the last line,
# (b) misses `fatal:` because matchers were "rejected|error", and (c)
# discards the real exit code. Card aon-onboard-silently-masks-push-
# failure has the full repro.
_aon_team_push() {
  local out rc
  out="$(git -C "$AON_TEAM_DIR" push 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    aon_err "git push failed (exit $rc):"
    printf '%s\n' "$out" | sed 's/^/  /' >&2
  fi
  return "$rc"
}

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
  local file="$1" table="$2" n
  # grep -c rc=1 on zero matches; capture cleanly so the caller doesn't
  # see a stray rc nor a double "0\n0" line if combined with `|| echo 0`.
  n="$(grep -c "^\[\[$table\]\]" "$file" 2>/dev/null)" || n=0
  printf '%s\n' "${n:-0}"
  return 0
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
    # Env-overrides-config: pre-set env wins over aon.toml. Mirrors the
    # AON_TEAM_DIR pattern at L174. Empty-string env (e.g.
    # `export AON_NATS_URL=""`) is treated as unset per ${VAR:-default}
    # and falls through to the toml value. Card:
    # aon-load-config-clobbers-env-overrides.
    AON_TEAM_NAME="${AON_TEAM_NAME:-$(aon_toml_get "$AON_TOML" team name)}"
    AON_TEAM_ACCOUNT="${AON_TEAM_ACCOUNT:-$(aon_toml_get "$AON_TOML" team account)}"
    AON_TEAM_KV="${AON_TEAM_KV:-$(aon_toml_get "$AON_TOML" team kv_bucket)}"
    AON_NATS_URL="${AON_NATS_URL:-$(aon_toml_get "$AON_TOML" nats url)}"
    AON_NATS_WS_URL="${AON_NATS_WS_URL:-$(aon_toml_get "$AON_TOML" nats ws_url)}"
    AON_NATS_ADMIN="${AON_NATS_ADMIN:-$(aon_toml_get "$AON_TOML" nats admin_user)}"
    AON_MODEL_PROVIDER="${AON_MODEL_PROVIDER:-$(aon_toml_get "$AON_TOML" model provider)}"
    AON_MODEL_NAME="${AON_MODEL_NAME:-$(aon_toml_get "$AON_TOML" model name)}"
    AON_OLLAMA_HOST="${AON_OLLAMA_HOST:-$(aon_toml_get "$AON_TOML" model ollama_host)}"
    AON_TASK_DIR="$(aon_toml_get "$AON_TOML" paths task_dir)"
    AON_PROMPTS_DIR="$(aon_toml_get "$AON_TOML" paths prompts_dir)"
    AON_AGENTS_DIR="$(aon_toml_get "$AON_TOML" paths agents_dir)"
    AON_HOOKS_DIR="$(aon_toml_get "$AON_TOML" paths hooks_dir)"
  else
    AON_TOML_PRESENT=0
    AON_SCHEMA="$AON_SCHEMA_VERSION"
    # Same env-overrides-config rule as the toml branch above — the
    # asymmetry between the two paths was itself a no-break:confuse
    # surface (env override would work without aon.toml but get
    # clobbered the moment one appeared).
    AON_TEAM_NAME="${AON_TEAM_NAME:-$(basename "$AON_TEAM_DIR")}"
    AON_TEAM_ACCOUNT="${AON_TEAM_ACCOUNT:-$AON_TEAM_NAME}"
    AON_TEAM_KV="${AON_TEAM_KV:-${AON_TEAM_NAME%-aon}-state}"
    AON_NATS_URL="${AON_NATS_URL:-nats://localhost:4222}"
    AON_NATS_WS_URL="${AON_NATS_WS_URL:-}"
    AON_NATS_ADMIN="${AON_NATS_ADMIN:-sysadmin}"
    AON_MODEL_PROVIDER="${AON_MODEL_PROVIDER:-claude}"
    AON_MODEL_NAME="${AON_MODEL_NAME:-}"
    AON_OLLAMA_HOST="${AON_OLLAMA_HOST:-http://localhost:11434}"
    AON_TASK_DIR=".tasks"
    AON_PROMPTS_DIR="agent-prompts"
    AON_AGENTS_DIR="agents"
    AON_HOOKS_DIR="hooks"
  fi

  # Schema version check.
  if [[ "$AON_TOML_PRESENT" -eq 1 && -n "$AON_SCHEMA" && "$AON_SCHEMA" != "$AON_SCHEMA_VERSION" ]]; then
    aon_warn "aon.toml schema=$AON_SCHEMA, this engine speaks $AON_SCHEMA_VERSION"
  fi

  AON_ROLES_COUNT="$(aon_toml_array_count "$AON_TOML" roles 2>/dev/null)"
  [[ -n "$AON_ROLES_COUNT" ]] || AON_ROLES_COUNT=0
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
# Operator-side runtime state — never under the team-aon git repo.
# auth.conf holds plain-text role passwords; .passwords is the
# master pw map. Both must NEVER be committed.
#
# auth.conf lives one level deeper (~/.aon/teams/<team>/nats/) so the
# whole subdir can be bind-mounted into the container as
# /etc/nats/runtime/. Single-file bind-mounts on macOS hosts (Docker
# Desktop VirtioFS, colima 9p/virtiofs) don't propagate in-place edits
# reliably; directory mounts do.
# .passwords stays at the parent dir, deliberately OUTSIDE the mount,
# so the password map never enters the container's view.
_aon_team_state_dir()  { printf '%s/.aon/teams/%s' "$HOME" "$1"; }
_aon_team_nats_dir()   { printf '%s/.aon/teams/%s/nats' "$HOME" "$1"; }
_aon_team_auth_conf()  { printf '%s/.aon/teams/%s/nats/auth.conf' "$HOME" "$1"; }
_aon_team_auth_conf_example() { printf '%s/.aon/teams/%s/nats/auth.conf.example' "$HOME" "$1"; }
_aon_team_passwords()  { printf '%s/.aon/teams/%s/.passwords' "$HOME" "$1"; }

# Path to a role's NATS .creds file (signed user JWT + nkey seed,
# emitted by `nsc generate creds` via cmd_creds). Defaults team to
# ${AON_TEAM_NAME:-team-alpha}.
_aon_role_creds() {
  local role="$1" team="${2:-${AON_TEAM_NAME:-team-alpha}}"
  printf '%s/.aon/teams/%s/creds/%s.creds' "$HOME" "$team" "$role"
}
# Backwards-compat alias — kept so any third-party scripts calling
# the old name keep working through the cutover. Drop after S5.
_aon_role_pwfile() { _aon_role_creds "$@"; }
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

# ───────────────────────────────────────────────────────────────────
# NSC integration (.tasks/nsc-jwt-migration.md S3)
#
# All NSC state for the engine lives under $AON_NSC_HOME (default
# ~/.aon/nsc/). One operator (`aon-op`) shared across teams; each team
# = one NATS account; each role = one user with claims translated from
# its kind template. Per-role .creds files written via
# _aon_nsc_emit_creds.
#
# These helpers `export XDG_DATA_HOME` + `XDG_CONFIG_HOME` so any nsc
# call inherits the engine-controlled NSC home — they intentionally
# clobber an operator's $XDG_*_HOME if set (we don't want stray
# operator NSC homes leaking team-aon-op state).
# ───────────────────────────────────────────────────────────────────

_aon_nsc_home()        { printf '%s' "${AON_NSC_HOME:-$HOME/.aon/nsc}"; }
_aon_nsc_operator()    { printf '%s' "${AON_NSC_OPERATOR:-aon-op}"; }
_aon_nsc_resolver_dir(){ printf '%s/resolver' "$(_aon_team_nats_dir "$1")"; }

_aon_nsc_env() {
  local home; home="$(_aon_nsc_home)"
  mkdir -p "$home"
  chmod 700 "$home"
  export XDG_DATA_HOME="$home/data"
  export XDG_CONFIG_HOME="$home/config"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
}

# Idempotent: create operator if absent. Sets service URL on every call
# (cheap; lets `aon set-nats-url` flow through to JWT).
_aon_nsc_ensure_operator() {
  local op nats_url; op="$(_aon_nsc_operator)"; nats_url="${1:-nats://localhost:4222}"
  _aon_nsc_env
  if ! nsc describe operator --name "$op" >/dev/null 2>&1; then
    nsc add operator --generate-signing-key --sys "$op" >/dev/null
  fi
  # `nsc env` carries the current operator; switch if we have multiple.
  nsc select operator "$op" >/dev/null 2>&1 || true
  nsc edit operator --service-url "$nats_url" >/dev/null
}

# Idempotent: create per-team account if absent.
_aon_nsc_ensure_account() {
  local team="$1"
  _aon_nsc_env
  if ! nsc describe account --name "$team" >/dev/null 2>&1; then
    nsc add account "$team" >/dev/null
  fi
  # JetStream limits — same shape as smoke. Fine to set every time.
  nsc edit account "$team" \
    --js-mem-storage 64M --js-disk-storage 256M \
    --js-streams 32 --js-consumer 64 >/dev/null
}

# Add a user with claims translated from its kind. Idempotent: skips if
# user already exists. To re-issue claims, delete via
# `nsc delete user --account <team> --name <role>` first (rare).
#
# Args: team kv name kind domain [learning]
_aon_nsc_ensure_user() {
  local team="$1" kv="$2" name="$3" kind="$4" domain="${5:-}" learning="${6:-${5:-}}"
  _aon_nsc_env
  if nsc describe user --account "$team" --name "$name" >/dev/null 2>&1; then
    return 0
  fi
  case "$kind" in
    sysadmin)
      nsc add user --account "$team" "$name" \
        --allow-pubsub ">" \
        --allow-pub-response >/dev/null
      ;;
    manager)
      nsc add user --account "$team" "$name" \
        --allow-pub "agents.${name}.events,agents.*.inbox,broadcast.>,board.tasks.*.pending,board.tasks.review.>,a2a.*.tasks.send,a2a.*.tasks.*.cancel,a2a.discovery.>,state.project.>,\$KV.${kv}.project.>,\$KV.${kv}.team.>,\$KV.${kv}.policy.>,\$KV.${kv}.agent.${name}.>,state.>,\$JS.API.>,_INBOX.>" \
        --deny-pub "board.results.>" \
        --allow-sub ">" \
        --allow-pub-response >/dev/null
      ;;
    generalist)
      nsc add user --account "$team" "$name" \
        --allow-pub "agents.${name}.events,agents.*.inbox,broadcast.incidents,state.alert.no_human,board.tasks.*.>,board.results.>,board.learning.*.mentoring,board.learning.*.pending,a2a.${name}.tasks.>,a2a.discovery.${name},state.agent.${name}.>,\$KV.${kv}.agent.${name}.>,\$KV.${kv}.a2a.${name}.>,\$JS.API.>" \
        --deny-pub "board.tasks.*.pending" \
        --allow-sub "agents.${name}.inbox,board.tasks.*.pending,board.learning.*.pending,board.learning.*.mentoring,a2a.${name}.tasks.send,a2a.${name}.tasks.*.cancel,a2a.${name}.tasks.>,broadcast.>,state.>,\$KV.${kv}.>,\$JS.API.>,_INBOX.>" \
        --allow-pub-response >/dev/null
      ;;
    specialist)
      nsc add user --account "$team" "$name" \
        --allow-pub "agents.${name}.events,agents.*.inbox,broadcast.incidents,state.alert.no_human,board.tasks.${domain}.>,board.results.${domain}.>,board.learning.${learning}.claimed,a2a.${name}.tasks.>,a2a.discovery.${name},state.agent.${name}.>,\$KV.${kv}.agent.${name}.>,\$KV.${kv}.a2a.${name}.>,\$JS.API.>" \
        --deny-pub "board.tasks.*.pending" \
        --allow-sub "agents.${name}.inbox,board.tasks.${domain}.pending,board.learning.${learning}.pending,board.learning.${learning}.mentoring,a2a.${name}.tasks.send,a2a.${name}.tasks.*.cancel,a2a.${name}.tasks.>,broadcast.>,state.>,\$KV.${kv}.>,\$JS.API.>,_INBOX.>" \
        --allow-pub-response >/dev/null
      ;;
    *)
      aon_err "_aon_nsc_ensure_user: unknown kind '$kind' (role=$name)"
      return 1
      ;;
  esac
}

# Emit a .creds file. Always rewrites (idempotent in content). chmod 600.
_aon_nsc_emit_creds() {
  local team="$1" name="$2" dest="$3"
  _aon_nsc_env
  mkdir -p "$(dirname "$dest")"
  nsc generate creds --account "$team" --name "$name" > "$dest"
  chmod 600 "$dest"
}

# JWT/ID accessors (used to render nats-server.conf placeholders).
_aon_nsc_op_jwt()   { _aon_nsc_env; nsc describe operator --raw 2>/dev/null | tr -d '\n'; }
_aon_nsc_sys_id()   { _aon_nsc_env; nsc describe account --name SYS --field sub 2>/dev/null | tr -d '"'; }
_aon_nsc_sys_jwt()  { _aon_nsc_env; nsc describe account --name SYS --raw 2>/dev/null | tr -d '\n'; }
_aon_nsc_team_id()  { _aon_nsc_env; nsc describe account --name "$1" --field sub 2>/dev/null | tr -d '"'; }
_aon_nsc_team_jwt() { _aon_nsc_env; nsc describe account --name "$1" --raw 2>/dev/null | tr -d '\n'; }

# Drop the per-team account JWT into the server's resolver dir.
# Lives under $(_aon_team_nats_dir <team>)/resolver/<team-id>.jwt.
#
# Disk-only — does NOT propagate to a running nats-server. Pair with
# _aon_nsc_push_team_jwt to apply runtime updates (revocations,
# claim edits, etc.).
_aon_nsc_publish_team_jwt() {
  local team="$1"
  local team_id team_jwt rdir
  team_id="$(_aon_nsc_team_id "$team")"
  team_jwt="$(_aon_nsc_team_jwt "$team")"
  rdir="$(_aon_nsc_resolver_dir "$team")"
  [[ -n "$team_id" && -n "$team_jwt" ]] || { aon_err "no JWT for account '$team' — run 'aon auth render' first"; return 1; }
  mkdir -p "$rdir"
  printf '%s' "$team_jwt" > "$rdir/$team_id.jwt"
}

# Push the per-team account JWT to a running nats-server via
# `nsc push` ($SYS.REQ.CLAIMS.UPDATE). The disk dir is server-write
# at runtime; updates require this RPC. Soft-fail when the server is
# unreachable (e.g. cold-render before `aon nats up`) — disk write
# already happened, so the next start picks up the new JWT.
#
# Args: team [url]
#   url defaults to $AON_NATS_URL (loaded by aon_load_config).
_aon_nsc_push_team_jwt() {
  local team="$1" url="${2:-${AON_NATS_URL:-}}"
  [[ -n "$url" ]] || { aon_warn "no NATS URL — skip nsc push (server picks up at next start)"; return 0; }
  _aon_nsc_env
  if nsc push -a "$team" -u "$url" >/dev/null 2>&1; then
    return 0
  fi
  aon_warn "nsc push failed (server unreachable at $url) — disk JWT updated; running server keeps stale claims until restart"
  return 0
}
