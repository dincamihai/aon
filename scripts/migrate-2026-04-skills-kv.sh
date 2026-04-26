#!/usr/bin/env bash
# One-shot migration (slice 2 card 136): remove deprecated
# KV team-state.agent.<role>.skills entries.
#
# Idempotent — safe to re-run; skips keys already absent.
set -u
: "${NATS_URL:?NATS_URL required}"
: "${NATS_ADMIN_USER:=sysadmin}"
: "${NATS_ADMIN_PASSWORD:?NATS_ADMIN_PASSWORD required}"
NATS_BIN="${NATS_BIN:-nats}"

nats_admin() {
  "$NATS_BIN" --server "$NATS_URL" --user "$NATS_ADMIN_USER" \
    --password "$NATS_ADMIN_PASSWORD" "$@"
}

removed=0; absent=0
for role in maya raj lin sam diego priya; do
  key="agent.${role}.skills"
  if nats_admin kv get team-state "$key" --raw >/dev/null 2>&1; then
    nats_admin kv del team-state "$key" -f >/dev/null 2>&1 \
      && { echo "  - removed $key"; removed=$((removed+1)); }
  else
    absent=$((absent+1))
  fi
done
echo "done. removed=$removed already_absent=$absent"
