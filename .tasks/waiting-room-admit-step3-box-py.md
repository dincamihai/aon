---
column: Done
created: 2026-04-28
priority: high
parent: waiting-room-admit
phase: 1
step: 3
---

# waiting-room-admit step 3 — `scripts/aon-crypto/box.py`

Self-contained crypto helper for libsodium-style `crypto_box`
(X25519 + XSalsa20-Poly1305) used by joiner/admin in waiting-room
admit. `aon` is bash; this is the Python shell-out per parent card
decision.

## Scope

Add `scripts/aon-crypto/box.py` with three subcommands:

- `keypair` → `{"pub": "<b64>", "priv": "<b64>"}` on stdout (one-line JSON).
- `encrypt --pubkey <b64> --in <path|-> ` → base64 ciphertext on stdout.
  `<path>` `-` means stdin.
- `decrypt --privkey <b64> --in <path|->` → plaintext bytes on stdout.

Use `pynacl` (`PublicKey`, `PrivateKey`, `Box`, ephemeral pair on
encrypt is fine; receiver pubkey is the sealed-recipient). Pin
`pynacl >= 1.5` in `pyproject.toml` of the engine
(`/Users/mid/Repos/ai-over-nats/pyproject.toml`).

## Acceptance

1. `pyproject.toml` adds `pynacl>=1.5` to engine deps; `pip install -e .`
   from `~/Repos/ai-over-nats` succeeds clean.
2. `scripts/aon-crypto/box.py keypair` emits valid one-line JSON with
   `pub` + `priv` (32 bytes each, base64-decoded).
3. Round-trip smoke (added to `scripts/nsc-smoke/run-smoke.sh` Phase F
   stub OR new `scripts/aon-crypto/smoke.sh`):
   ```
   kp=$(box.py keypair)
   pub=$(jq -r .pub <<<"$kp"); priv=$(jq -r .priv <<<"$kp")
   ct=$(echo "hello world" | box.py encrypt --pubkey "$pub" --in -)
   pt=$(echo "$ct" | box.py decrypt --privkey "$priv" --in -)
   [[ "$pt" == "hello world" ]]
   ```
   Exit non-zero on any mismatch.
4. Tampered ciphertext → `box.py decrypt` exits non-zero with
   `nacl.exceptions.CryptoError` surfaced (don't swallow).
5. Wrong privkey → same hard fail.
6. `box.py --help` lists subcommands. Each subcommand has its own
   `--help`.
7. No network calls. No file writes outside stdout. Stdin/stdout binary-
   safe (no implicit utf-8 decode of plaintext on decrypt).
8. Type hints on public functions; passes `python -m py_compile`.
9. `scripts/nsc-smoke/run-smoke.sh` Phase C stays green.

## Out of scope

- Wiring into `aon connect` / `aon admit` (steps 4–7 of parent card).
- Key persistence on disk (caller decides; this helper is stateless).
- Streaming / chunked encryption (small JWT blobs only).
- `bin/aon-apparmor` profile updates (separate card).

## Gate

`scripts/nsc-smoke/run-smoke.sh` (existing phases) + new round-trip
smoke per acceptance #3.

## Notes for Tim

- Layout: `scripts/aon-crypto/box.py` + `scripts/aon-crypto/smoke.sh`
  (new). Make both `chmod +x`.
- Use `argparse`. Subparsers per command.
- Read `--in -` via `sys.stdin.buffer.read()`. Write ciphertext as
  base64 ASCII + trailing newline; plaintext as raw bytes.
- pynacl `Box(my_priv, peer_pub).encrypt(plaintext)` returns nonce
  prepended; preserve that — don't strip.
- Don't add CLI flags beyond those listed; resist scope.
