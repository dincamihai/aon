#!/usr/bin/env bash
# Regression for `aon tunnel` subcommand (card aws-ec2-nats-via-ssm).
#
# No real AWS required — stubs fake `aws` and `session-manager-plugin`
# on PATH where needed.
#
# Cases:
#   1. `aon tunnel status` with no state file → rc=1, "no active tunnel"
#   2. `aon tunnel down` with no state file → rc=0, "no active tunnel"
#   3. `aon tunnel up` missing aws CLI → rc≠0, install directive
#   4. `aon tunnel up` missing session-manager-plugin → rc≠0, directive
#   5. `aon tunnel up` with stub deps + valid state → rc=0, state file written
#   6. `aon tunnel status` with live stub pid → rc=0, "RUNNING"
#   7. `aon tunnel status` with dead pid → rc=1, "DEAD"
#   8. `aon tunnel down` with live stub pid → kills, clears state
#   9. resolve-env overrides AON_NATS_URL when tunnel live
#  10. set-nats-url emits deprecation warn

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../.."
AON="$ENGINE/bin/aon"
[[ -x "$AON" ]] || { echo "✗ no aon at $AON" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.aon" "$FAKE_HOME/.claude"

# Minimal work-repo + team so aon commands don't hit engine-guard.
TEAM="$WORK/team"
WR="$WORK/work-repo"
git init -q -b main "$WR"
mkdir -p "$TEAM"
cat > "$TEAM/aon.toml" <<'TOML'
[engine]
version = "0.1"
[team]
name = "fixture"
[nats]
url = "nats://localhost:4222"
[paths]
task_dir    = ".tasks"
prompts_dir = "agent-prompts"
agents_dir  = "agents"
hooks_dir   = "hooks"
[aws]
instance_id = "i-0fixture"
region      = "us-east-1"
profile     = "test-profile"
TOML
cat > "$FAKE_HOME/.aon/work-repos.json" <<JSON
[{"path": "$WR", "team": "fixture", "role": "tim"}]
JSON

run_aon() {
  HOME="$FAKE_HOME" AON_TEAM_DIR="$TEAM" "$AON" "$@" 2>&1
}

STATE_FILE="$FAKE_HOME/.aon/tunnel.state"

# ── Case 1: status with no state ──
out="$(cd "$WR" && run_aon tunnel status || true)"
grep -qE "no active tunnel" <<<"$out" || fail "case 1: expected 'no active tunnel'; got: $out"
ok "case 1 status no state → 'no active tunnel'"

# ── Case 2: down with no state ──
out="$(cd "$WR" && run_aon tunnel down || true)"
grep -qE "no active tunnel" <<<"$out" || fail "case 2: expected 'no active tunnel'; got: $out"
ok "case 2 down no state → clean exit"

# Minimal PATH: only bash + basic utils (no aws, no session-manager-plugin).
# /bin/bash on macOS is 3.2 which doesn't parse aon heredocs; symlink real bash.
BASH_ONLY="$WORK/bash-only"
mkdir -p "$BASH_ONLY"
ln -sf "$(command -v bash)" "$BASH_ONLY/bash"
ln -sf "$(command -v env)"  "$BASH_ONLY/env"
# Also link basic tools that aon uses internally (grep, cut, etc.)
for _t in grep cut sed jq awk mktemp rm mkdir chmod; do
  _bin="$(command -v "$_t" 2>/dev/null || true)"
  [[ -n "$_bin" ]] && ln -sf "$_bin" "$BASH_ONLY/$_t" 2>/dev/null || true
done
MINIMAL_PATH="$BASH_ONLY:/usr/bin:/bin"

# ── Case 3: up missing aws CLI ──
NOAWS="$WORK/noaws"
mkdir -p "$NOAWS"
# Put session-manager-plugin in stub dir but no aws.
cat > "$NOAWS/session-manager-plugin" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$NOAWS/session-manager-plugin"
out="$(HOME="$FAKE_HOME" AON_TEAM_DIR="$TEAM" PATH="$NOAWS:$MINIMAL_PATH" "$AON" tunnel up --instance i-0test 2>&1 || true)"
grep -qE "aws CLI not found|aws-cli" <<<"$out" || fail "case 3: expected aws install directive; got: $out"
ok "case 3 missing aws → install directive"

# ── Case 4: up missing session-manager-plugin ──
NOSMP="$WORK/nosmp"
mkdir -p "$NOSMP"
cat > "$NOSMP/aws" <<'SH'
#!/bin/sh
echo "aws-cli/2.0.0 Python/3.x Linux/x86_64"
exit 0
SH
chmod +x "$NOSMP/aws"
out="$(HOME="$FAKE_HOME" AON_TEAM_DIR="$TEAM" PATH="$NOSMP:$MINIMAL_PATH" "$AON" tunnel up --instance i-0test 2>&1 || true)"
grep -qE "session-manager-plugin" <<<"$out" || fail "case 4: expected smp directive; got: $out"
ok "case 4 missing session-manager-plugin → directive"

# ── Case 5: up with stub deps → state file written ──
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# Stub aws: pretend to be SSM start-session (runs forever in background).
cat > "$STUBS/aws" <<'SH'
#!/bin/sh
sleep 300
SH
chmod +x "$STUBS/aws"
cat > "$STUBS/session-manager-plugin" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$STUBS/session-manager-plugin"

out="$(cd "$WR" && HOME="$FAKE_HOME" AON_TEAM_DIR="$TEAM" PATH="$STUBS:$PATH" \
       "$AON" tunnel up --instance i-0fixture --region us-east-1 --profile test 2>&1)"
[[ -f "$STATE_FILE" ]] || fail "case 5: state file not written; aon output: $out"
grep -q "pid=" "$STATE_FILE" || fail "case 5: state file missing pid"
grep -q "instance_id=i-0fixture" "$STATE_FILE" || fail "case 5: state file missing instance_id"
ok "case 5 tunnel up with stubs → state file written"

# ── Case 6: status with live pid ──
out="$(cd "$WR" && run_aon tunnel status || true)"
grep -qE "RUNNING" <<<"$out" || fail "case 6: expected RUNNING; got: $out"
ok "case 6 status with live pid → RUNNING"

# ── Case 7: status with dead pid ──
LIVE_PID="$(grep '^pid=' "$STATE_FILE" | cut -d= -f2)"
kill "$LIVE_PID" 2>/dev/null || true
sleep 0.1
out="$(cd "$WR" && run_aon tunnel status || true)"
grep -qE "DEAD|dead" <<<"$out" || fail "case 7: expected DEAD; got: $out"
ok "case 7 status dead pid → DEAD"

# Restore a live stub pid for case 8.
sleep 300 &
NEW_PID=$!
sed -i.bak "s/^pid=.*/pid=$NEW_PID/" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"

# ── Case 8: down with live pid → kills + clears state ──
out="$(cd "$WR" && run_aon tunnel down 2>&1)"
[[ ! -f "$STATE_FILE" ]] || fail "case 8: state file not cleared after 'aon tunnel down'"
kill -0 "$NEW_PID" 2>/dev/null && fail "case 8: process $NEW_PID still running after tunnel down"
ok "case 8 tunnel down → kills pid + clears state"

# ── Case 9: resolve-env overrides URL when tunnel live ──
# Start a fresh stub process for the tunnel state.
sleep 300 &
STUB_PID=$!
cat > "$STATE_FILE" <<EOF
pid=$STUB_PID
instance_id=i-0fixture
region=us-east-1
profile=test
local_port=4222
remote_port=4222
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 600 "$STATE_FILE"

# Need a .creds file so resolve-env returns non-empty.
CREDS_DIR="$FAKE_HOME/.aon/teams/fixture/creds"
mkdir -p "$CREDS_DIR"
printf '# stub creds\n' > "$CREDS_DIR/tim.creds"
cat > "$CREDS_DIR/tim.env" <<'ENV'
export AON_NATS_URL=nats://old-url:4222
export AON_KV_BUCKET=fixture-state
export AON_WORK_REPO=/tmp/stub
ENV

resolve_out="$(cd "$WR" && HOME="$FAKE_HOME" AON_TEAM_DIR="$TEAM" "$AON" resolve-env 2>/dev/null || true)"
grep -qE "AON_NATS_URL=nats://localhost:4222" <<<"$resolve_out" \
  || fail "case 9: expected AON_NATS_URL=nats://localhost:4222; got: $resolve_out"
ok "case 9 resolve-env overrides URL to nats://localhost:4222 when tunnel live"

# Clean up stub process.
kill "$STUB_PID" 2>/dev/null || true
rm -f "$STATE_FILE"

# ── Case 10: set-nats-url emits deprecation warn ──
out="$(cd "$WR" && run_aon set-nats-url somebits 2>&1 || true)"
grep -qE "deprecated|DEPRECATED" <<<"$out" || fail "case 10: expected deprecation warn; got: $out"
ok "case 10 set-nats-url → deprecation warn emitted"

ok "ALL OK"
