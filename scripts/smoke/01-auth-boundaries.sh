#!/usr/bin/env bash
# Smoke 01 — auth boundaries per MODEL.md role permissions.
#
# Asserts each role can pub/sub their allowed subjects AND is rejected on
# subjects outside their permission map. Re-run after any auth.conf change.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 01 auth boundaries ──"

## Maya — manager
assert_pub_ok     maya  agents.maya.events
assert_pub_ok     maya  broadcast.standup
assert_pub_ok     maya  board.tasks.terraform.pending
assert_pub_denied maya  board.results.terraform.completed   # doers post results, not manager

## Raj — senior generalist (any domain)
assert_pub_ok     raj   board.tasks.terraform.claimed
assert_pub_ok     raj   board.tasks.go.claimed
assert_pub_ok     raj   board.results.python.shipped
assert_pub_ok     raj   board.learning.go.mentoring

## Lin — mid generalist (python, ui, go-growth)
assert_pub_ok     lin   board.tasks.python.claimed
assert_pub_ok     lin   board.tasks.go.claimed              # growth domain explicit
assert_pub_denied lin   board.tasks.terraform.claimed       # not in scope
assert_pub_ok     lin   board.learning.go.claimed

## Sam — UI specialist, growing into backend
assert_pub_ok     sam   board.tasks.ui.claimed
assert_pub_denied sam   board.tasks.python.claimed          # production python: blocked
assert_pub_denied sam   board.tasks.go.claimed              # production go: blocked
assert_pub_ok     sam   board.learning.python.claimed       # learning track: allowed
assert_pub_ok     sam   board.learning.go.claimed

## Diego — Go specialist, growing into infra
assert_pub_ok     diego board.tasks.go.claimed
assert_pub_denied diego board.tasks.terraform.claimed       # production infra: blocked
assert_pub_denied diego board.tasks.aws.claimed
assert_pub_ok     diego board.learning.terraform.claimed
assert_pub_ok     diego board.learning.aws.claimed

## Priya — Terraform/AWS specialist, learning Python
assert_pub_ok     priya board.tasks.terraform.claimed
assert_pub_ok     priya board.tasks.aws.claimed
assert_pub_denied priya board.tasks.python.claimed          # production python: blocked
assert_pub_ok     priya board.learning.python.claimed

## Cross-role inbox publishes (anyone can DM anyone)
assert_pub_ok     sam   agents.diego.inbox
assert_pub_ok     priya agents.lin.inbox
assert_pub_ok     maya  agents.raj.inbox

summary
