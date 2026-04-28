#!/usr/bin/env bash
# Regression for `aon_load_config` env-overrides-config behavior.
# Card: aon-load-config-clobbers-env-overrides.
#
# Pre-fix: `AON_*` assignments at bin/_aon-lib.sh L199-L204
# unconditionally overwrote any pre-set env value with the aon.toml
# value (silent clobber, asymmetric with AON_TEAM_DIR at L174). Fix
# wraps each in ${VAR:-default}.
#
# Cases (covers AC #4: set + unset + empty for ≥ 2 vars):
#   1. set AON_NATS_URL    → env wins
#   2. unset AON_NATS_URL  → toml wins (no regression)
#   3. empty AON_NATS_URL  → toml wins (${VAR:-default} treats "" as unset)
#   4. set AON_TEAM_NAME   → env wins (second var, different section)
#   5. unset AON_TEAM_NAME → toml wins
#
# Each case sources _aon-lib.sh in a fresh subshell against a fixture
# aon.toml. No engine state leaks across cases.

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../bin/_aon-lib.sh"
[[ -r "$LIB" ]] || { echo "✗ cannot find _aon-lib.sh at $LIB" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fixture aon.toml. Values must be distinct from any env override the
# tests set, so a clobber would be visible.
TEAM="$WORK/team-aon"
mkdir -p "$TEAM"
cat > "$TEAM/aon.toml" <<'TOML'
[engine]
version = "0.1"

[team]
name           = "toml-team"
account        = "toml-account"
kv_bucket      = "toml-kv"

[nats]
url        = "nats://toml.example:4222"
ws_url     = "wss://toml.example/ws"
admin_user = "toml-admin"

[paths]
task_dir    = ".tasks"
prompts_dir = "agent-prompts"
agents_dir  = "agents"
hooks_dir   = "hooks"
TOML

# probe: source the lib in a fresh subshell with the given env, run
# aon_load_config, print the named var.
probe() {
  local var="$1"; shift
  env -i HOME="$HOME" PATH="$PATH" AON_TEAM_DIR="$TEAM" "$@" bash -c "
    source '$LIB' >/dev/null 2>&1 || exit 99
    aon_load_config >/dev/null 2>&1 || exit 98
    printf '%s' \"\${$var-<UNSET>}\"
  "
}

# 1. set AON_NATS_URL → env wins
got="$(probe AON_NATS_URL AON_NATS_URL=nats://override:9999)"
[[ "$got" == "nats://override:9999" ]] || fail "set AON_NATS_URL: env should win, got '$got'"
ok "set AON_NATS_URL → env override wins"

# 2. unset AON_NATS_URL → toml wins
got="$(probe AON_NATS_URL)"
[[ "$got" == "nats://toml.example:4222" ]] || fail "unset AON_NATS_URL: toml should win, got '$got'"
ok "unset AON_NATS_URL → toml value resolved"

# 3. empty AON_NATS_URL → toml wins (${VAR:-...} treats "" as unset)
got="$(probe AON_NATS_URL AON_NATS_URL=)"
[[ "$got" == "nats://toml.example:4222" ]] || fail "empty AON_NATS_URL: toml should win (\${VAR:-} semantic), got '$got'"
ok "empty AON_NATS_URL → toml value resolved (\${VAR:-default} semantic)"

# 4. set AON_TEAM_NAME → env wins (second var, [team] section)
got="$(probe AON_TEAM_NAME AON_TEAM_NAME=override-team)"
[[ "$got" == "override-team" ]] || fail "set AON_TEAM_NAME: env should win, got '$got'"
ok "set AON_TEAM_NAME → env override wins"

# 5. unset AON_TEAM_NAME → toml wins
got="$(probe AON_TEAM_NAME)"
[[ "$got" == "toml-team" ]] || fail "unset AON_TEAM_NAME: toml should win, got '$got'"
ok "unset AON_TEAM_NAME → toml value resolved"

# ── no-aon.toml branch — same env rule applies ──
# Pre-fix the else-branch (no aon.toml) ALSO clobbered env. Asymmetry
# between the two paths was itself a no-break:confuse surface — env
# would work without aon.toml but get clobbered the moment one
# appeared. Fix mirrors the rule across both branches.

NOTOML="$WORK/team-no-toml"
mkdir -p "$NOTOML"
# No aon.toml file. Probe redefines the team dir so the else branch fires.
probe_notoml() {
  local var="$1"; shift
  env -i HOME="$HOME" PATH="$PATH" AON_TEAM_DIR="$NOTOML" "$@" bash -c "
    source '$LIB' >/dev/null 2>&1 || exit 99
    aon_load_config >/dev/null 2>&1 || exit 98
    printf '%s' \"\${$var-<UNSET>}\"
  "
}

# 6. set AON_NATS_URL with no aon.toml → env wins
got="$(probe_notoml AON_NATS_URL AON_NATS_URL=nats://override:9999)"
[[ "$got" == "nats://override:9999" ]] || fail "no-toml + set AON_NATS_URL: env should win, got '$got'"
ok "no-toml + set AON_NATS_URL → env override wins"

# 7. unset AON_NATS_URL with no aon.toml → built-in default
got="$(probe_notoml AON_NATS_URL)"
[[ "$got" == "nats://localhost:4222" ]] || fail "no-toml + unset: built-in default expected, got '$got'"
ok "no-toml + unset AON_NATS_URL → built-in default resolved"

ok "ALL OK"
