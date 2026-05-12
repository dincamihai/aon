---
column: Backlog
---

# fix: box.py --pubkey VALUE breaks when key starts with dash (use --pubkey=VALUE)
# fix: box.py --pubkey VALUE breaks when key starts with dash

## Problem

`scripts/aon-crypto/box.py encrypt --pubkey VALUE` fails if VALUE starts with `-` — argparse interprets it as a flag.

NaCl b64 keys don't start with dash in practice (low probability) but still a latent bug.

## Fix

Change call site in `cmd_admit_approve` (bin/aon) to use `--pubkey=VALUE` form, or add `--` separator before VALUE.

## Found by

rona, admit r3 e2e (da3b980).
