#!/usr/bin/env bash
# Pin the `aon onboard` CLI surface after the BITS-arg drop.
#
# Card: onboard-drop-probe-and-bits. Pre-fix signature was
# `aon onboard NAME BITS [KIND] [DOMAIN]`; new signature is
# `aon onboard NAME [KIND] [DOMAIN]` and the inline handshake probe
# was removed in favor of `aon doctor`. This test catches drift in
# either direction.

set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AON="$HERE/../../bin/aon"
README="$HERE/../../README.md"
[[ -x "$AON" ]] || { echo "✗ no aon at $AON" >&2; exit 2; }

ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

# 1. Help line lists no BITS arg.
if "$AON" help 2>&1 | grep -E "^[[:space:]]*onboard " | grep -q "BITS"; then
  fail "help still mentions BITS in the onboard signature"
fi
ok "help signature has no BITS arg"

# Set up a fixture team-aon dir so `aon` doesn't trip on the
# engine-repo guard (`if [[ -f "$AON_TEAM_DIR/.aon-engine" ]]`).
# Tests need a real team dir on AON_TEAM_DIR + an aon.toml + a NATS
# URL, otherwise they exercise the engine refusal path instead of
# the cmd_onboard surface we want to pin.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TEAM="$WORK/team-aon"
mkdir -p "$TEAM"
cat > "$TEAM/aon.toml" <<'TOML'
[engine]
version = "0.1"

[team]
name = "fixture-team"

[nats]
url = "nats://fixture.local:4222"

[paths]
task_dir    = ".tasks"
prompts_dir = "agent-prompts"
agents_dir  = "agents"
hooks_dir   = "hooks"
TOML
run() { AON_TEAM_DIR="$TEAM" "$AON" "$@"; }

# 2. `aon onboard` with no NAME → rc=2, usage block + no BITS mention.
out="$(run onboard 2>&1)"; rc=$?
[[ $rc -eq 2 ]] || fail "no-name invocation rc=$rc, expected 2"
grep -qE "usage: aon onboard NAME \[KIND\] \[DOMAIN\]" <<<"$out" \
  || fail "usage line wrong; got: $out"
grep -q "BITS" <<<"$out" && fail "usage line still mentions BITS"
grep -q "doctor" <<<"$out" || fail "usage doesn't point at aon doctor"
ok "rc=2 usage clean, points at aon doctor"

# 2b. Missing-URL guard: aon.toml without [nats] url (or placeholder)
#     must hard-fail with a directive, not silently mint a bad token.
NOURL="$WORK/team-no-url"
mkdir -p "$NOURL"
cat > "$NOURL/aon.toml" <<'TOML'
[engine]
version = "0.1"
[team]
name = "no-url-team"
[nats]
url = "wss://YOUR-CURRENT-TUNNEL.trycloudflare.com"
[paths]
task_dir = ".tasks"
prompts_dir = "agent-prompts"
agents_dir = "agents"
hooks_dir = "hooks"
TOML
out="$(AON_TEAM_DIR="$NOURL" "$AON" onboard somerole 2>&1)"; rc=$?
[[ $rc -ne 0 ]] || fail "placeholder URL: expected non-zero rc, got 0"
grep -qE "no NATS URL" <<<"$out" \
  || fail "placeholder URL: missing 'no NATS URL' surface; got: $out"
grep -qE "aon doctor" <<<"$out" \
  || fail "placeholder URL: missing pointer to aon doctor; got: $out"
ok "placeholder NATS URL → rc!=0, directive surfaced"

# 3. README — `aon onboard <name>` snippet has no <cloudflared-bits>
#    on the same line. Pre-fix had `<name> <cloudflared-bits>`.
if grep -E "^aon onboard " "$README" | grep -q "cloudflared-bits"; then
  fail "README still shows cloudflared-bits next to 'aon onboard'"
fi
ok "README onboard snippet bits-free"

# 4. README CLI ref block: NAME [KIND] [DOMAIN], no BITS.
if grep -E "^aon onboard NAME " "$README" | grep -q "BITS"; then
  fail "README CLI ref still has BITS in the onboard signature"
fi
ok "README CLI ref bits-free"

# 5. The inline probe step ("local handshake probe") gone from the
#    onboard flow log labels. (Step 5/external-NATS branch can still
#    reference 'auth.conf' reload — that's not the probe.)
if grep -nE "local handshake probe" "$AON" | grep -v "external NATS"; then
  fail "inline 'local handshake probe' step still present in bin/aon"
fi
ok "inline handshake probe step removed"

ok "ALL OK"
