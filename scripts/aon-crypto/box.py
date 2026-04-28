#!/usr/bin/env python3
"""libsodium crypto_box helper for waiting-room admit.

Stateless CLI: keypair / encrypt / decrypt. Stdin/stdout binary-safe.
No file writes, no network. See parent card waiting-room-admit.
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path
from typing import Optional

from nacl.public import PrivateKey, PublicKey, SealedBox


def _read_input(spec: str) -> bytes:
    if spec == "-":
        return sys.stdin.buffer.read()
    return Path(spec).read_bytes()


def _b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def _b64d(s: str) -> bytes:
    return base64.b64decode(s.encode("ascii"))


def cmd_keypair(_args: argparse.Namespace) -> int:
    priv = PrivateKey.generate()
    out = {"pub": _b64e(bytes(priv.public_key)), "priv": _b64e(bytes(priv))}
    sys.stdout.write(json.dumps(out) + "\n")
    return 0


def cmd_encrypt(args: argparse.Namespace) -> int:
    peer_pub = PublicKey(_b64d(args.pubkey))
    plaintext = _read_input(args.in_)
    # SealedBox = libsodium crypto_box_seal: ephemeral keypair generated
    # internally, nonce derived deterministically from blake2b(eph_pub
    # || recipient_pub). Output framing matches Go/Rust libsodium clients
    # so admin/joiner can interop without bespoke parsers.
    ciphertext = SealedBox(peer_pub).encrypt(plaintext)
    sys.stdout.write(_b64e(ciphertext) + "\n")
    return 0


def cmd_decrypt(args: argparse.Namespace) -> int:
    my_priv = PrivateKey(_b64d(args.privkey))
    raw = _read_input(args.in_)
    ciphertext = _b64d(raw.decode("ascii").strip())
    plaintext = SealedBox(my_priv).decrypt(ciphertext)
    sys.stdout.buffer.write(plaintext)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="box.py",
        description="libsodium crypto_box helper (X25519 + XSalsa20-Poly1305).",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("keypair", help="emit JSON {pub, priv} (base64)").set_defaults(
        func=cmd_keypair
    )

    enc = sub.add_parser("encrypt", help="encrypt for recipient pubkey")
    enc.add_argument("--pubkey", required=True, help="recipient pubkey (base64)")
    enc.add_argument(
        "--in", dest="in_", required=True, help="input path or '-' for stdin"
    )
    enc.set_defaults(func=cmd_encrypt)

    dec = sub.add_parser("decrypt", help="decrypt with privkey")
    dec.add_argument("--privkey", required=True, help="recipient privkey (base64)")
    dec.add_argument(
        "--in", dest="in_", required=True, help="input path or '-' for stdin"
    )
    dec.set_defaults(func=cmd_decrypt)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
