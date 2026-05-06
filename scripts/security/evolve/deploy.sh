#!/usr/bin/env bash
# Deploy a champion prompt from the MAP-Elites archive into the live
# classifier. Operator-gated: shows a diff and prompts before
# replacing the SYSTEM block in classifier-ollama.sh.
#
# Usage:
#   deploy.sh show   <cell>        — diff vs live, no changes
#   deploy.sh apply  <cell> [--force-regression]
#   deploy.sh rollback             — revert to previous champion

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/_lib.sh"

CLASSIFIER="$HERE/../classifier-ollama.sh"
ARCHIVE="$EVOLVE_DIR/archive"
BACKUP_DIR="$EVOLVE_DIR/deploy-backups"
mkdir -p "$BACKUP_DIR"

extract_live_prompt() {
  awk '/^SYSTEM=/,/^'"'"'$/' "$CLASSIFIER" \
    | sed -n "s/^SYSTEM='//; /^'\$/d; p"
}

apply_prompt_to_classifier() {
  local new_prompt="$1"
  local backup="$BACKUP_DIR/classifier-ollama.sh.$(date +%s)"
  cp "$CLASSIFIER" "$backup"
  # Replace SYSTEM='...' block in-place
  python3 - "$CLASSIFIER" "$new_prompt" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
text = open(path).read()
m = re.search(r"(SYSTEM=')(.*?)(\n')", text, re.DOTALL)
if not m:
    sys.exit("could not locate SYSTEM= block")
text = text[:m.start()] + "SYSTEM='" + new.rstrip("\n") + "\n'" + text[m.end():]
open(path, "w").write(text)
PY
  echo "$backup" >"$EVOLVE_DIR/last-backup"
}

cmd_show() {
  local cell="$1"
  local champ="$ARCHIVE/cells/$cell/champion.txt"
  [ -r "$champ" ] || { echo "no champion in cell $cell" >&2; exit 1; }
  local tmp; tmp="$(mktemp -t cmd-gate-show.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  extract_live_prompt >"$tmp"
  diff -u --color=auto "$tmp" "$champ" || true
}

cmd_apply() {
  local cell="$1"; shift || true
  local force=0
  for a in "$@"; do
    case "$a" in --force-regression) force=1 ;; esac
  done
  local champ="$ARCHIVE/cells/$cell/champion.txt"
  local meta="$ARCHIVE/cells/$cell/scores.json"
  [ -r "$champ" ] && [ -r "$meta" ] || { echo "no champion in cell $cell" >&2; exit 1; }

  evolve_log INFO "deploy: cell=$cell"
  jq -r '"  acc=" + (.scores.accuracy|tostring) +
         "  fpr=" + (.scores.fpr|tostring) +
         "  fnr=" + (.scores.fnr|tostring) +
         "  p50=" + (.scores.p50_latency_ms|tostring) + "ms"' "$meta"

  # Regression guard: compare against last deployed score if available
  if [ "$force" -eq 0 ] && [ -f "$EVOLVE_DIR/last-deployed-scores.json" ]; then
    local prev_acc new_acc
    prev_acc=$(jq -r '.scores.accuracy' "$EVOLVE_DIR/last-deployed-scores.json")
    new_acc=$(jq -r '.scores.accuracy' "$meta")
    if awk -v p="$prev_acc" -v n="$new_acc" 'BEGIN{exit !(n+0 < p+0)}'; then
      echo "deploy: refusing — new accuracy $new_acc < previous $prev_acc" >&2
      echo "  pass --force-regression to override" >&2
      exit 2
    fi
  fi

  printf 'Apply this prompt as the new classifier system message? [y/N] '
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "aborted"; exit 0 ;;
  esac

  apply_prompt_to_classifier "$(cat "$champ")"
  cp "$meta" "$EVOLVE_DIR/last-deployed-scores.json"

  local hash; hash=$(jq -r .hash "$meta")
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cell" "$hash" \
    >>"$ARCHIVE/champions.log"

  # Publish policy-change event so deployed agents pick up new prompt
  if [ -n "${AON_NATS_URL:-}" ] && [ -r "${AON_CREDS:-/dev/null}" ] \
     && command -v nats >/dev/null; then
    nats --server "$AON_NATS_URL" --creds "$AON_CREDS" pub \
      "evt.security.gate.policy-change.${AON_ROLE:-sysadmin}" \
      "$(jq -nc --arg cell "$cell" --arg hash "$hash" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '{cell:$cell, hash:$hash, ts:$ts}')" >/dev/null 2>&1 || true
  fi
  evolve_log INFO "deploy: applied cell=$cell hash=$hash"
}

cmd_rollback() {
  local backup
  backup=$(cat "$EVOLVE_DIR/last-backup" 2>/dev/null || true)
  [ -n "$backup" ] && [ -r "$backup" ] || { echo "no backup to roll back to" >&2; exit 1; }
  cp "$backup" "$CLASSIFIER"
  evolve_log INFO "deploy: rolled back to $backup"
}

case "${1:-}" in
  show)     cmd_show "${2:-}" ;;
  apply)    shift; cmd_apply "$@" ;;
  rollback) cmd_rollback ;;
  *)
    cat >&2 <<EOF
Usage: deploy.sh <subcommand>
  show <cell>                  diff cell champion vs live classifier
  apply <cell> [--force-regression]  apply with operator confirmation
  rollback                     revert to previous backup
EOF
    exit 2 ;;
esac
