#!/usr/bin/env bash
# Smoke 19 — A2A ACL coverage matrix (slice 2 card 135).
#
# Comprehensive deny/allow on all a2a.> subjects per role.
set -u
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SMOKE_DIR/_lib.sh"

echo "── 19 A2A ACL coverage ──"

# Self-tasks subtree: each worker can pub on a2a.<self>.tasks.>.
for r in raj lin sam diego priya; do
  assert_pub_ok "$r" "a2a.$r.tasks.t-acl.status" '{"task_id":"t-acl","state":"working","by":"'"$r"'"}'
done

# Cross-worker tasks pub denied (e.g. lin → a2a.priya.tasks.>).
assert_pub_denied lin   "a2a.priya.tasks.t-x.status" '{}'
assert_pub_denied sam   "a2a.raj.tasks.t-x.status"   '{}'
assert_pub_denied diego "a2a.lin.tasks.t-x.status"   '{}'
assert_pub_denied priya "a2a.sam.tasks.t-x.status"   '{}'
assert_pub_denied raj   "a2a.diego.tasks.t-x.status" '{}'

# Maya can dispatch (publish on a2a.*.tasks.send).
for r in raj lin sam diego priya; do
  assert_pub_ok maya "a2a.$r.tasks.send" '{"task_id":"t-acl","skill":"x","payload":{}}'
done

# Non-maya cannot publish on .send (any role).
for src in raj lin sam diego priya; do
  for tgt in raj lin sam diego priya; do
    [ "$src" = "$tgt" ] && continue
    assert_pub_denied "$src" "a2a.$tgt.tasks.send" '{}'
  done
done

# Cancel: workers cannot cancel another's task.
assert_pub_denied lin "a2a.priya.tasks.t-x.cancel" '{}'
assert_pub_denied sam "a2a.raj.tasks.t-x.cancel"   '{}'

# Maya can cancel anywhere.
assert_pub_ok maya "a2a.priya.tasks.t-acl.cancel" '{}'
assert_pub_ok maya "a2a.raj.tasks.t-acl.cancel"   '{}'

# Discovery: own pub allowed; cross-pub denied.
for r in raj lin sam diego priya; do
  assert_pub_ok "$r" "a2a.discovery.$r" '{"name":"'"$r"'","version":"1.0"}'
done
assert_pub_denied lin   "a2a.discovery.priya" '{}'
assert_pub_denied sam   "a2a.discovery.raj"   '{}'
assert_pub_denied diego "a2a.discovery.lin"   '{}'

# Maya: discovery pub anywhere.
for r in raj lin sam diego priya; do
  assert_pub_ok maya "a2a.discovery.$r" '{}'
done

# Subscribe: workers can sub their own .tasks.send + .cancel.
assert_sub_ok lin   "a2a.lin.tasks.send"
assert_sub_ok priya "a2a.priya.tasks.t-x.cancel"

summary
