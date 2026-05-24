#!/usr/bin/env python3
"""
Encrypt Google service-account JSON to gcs_credentials.dat for HTTPS hosting on the license API / VPS.

  pip install cryptography

  python tools/encrypt_gcs_credentials_dat.py path/to/credentials.json path/to/gcs_credentials.dat

The client downloads {API}/seedesktop/gcs_credentials.dat over HTTPS and decrypts with the same
key material as seedesktop_gcs_backup.py (SHA256 pepper). Rotate the pepper in both places if needed.
"""
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"SDG1"
KEY_MATERIAL = b"SeeDesktop-gcs-blob-v1"


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "Usage: encrypt_gcs_credentials_dat.py <credentials.json> <out.dat>",
            file=sys.stderr,
        )
        return 2
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    if not src.is_file():
        print(f"Not found: {src}", file=sys.stderr)
        return 1
    key = hashlib.sha256(KEY_MATERIAL).digest()
    nonce = os.urandom(12)
    plain = src.read_bytes()
    aesgcm = AESGCM(key)
    payload = aesgcm.encrypt(nonce, plain, None)
    dst.write_bytes(MAGIC + nonce + payload)
    print(f"Wrote {dst} ({len(MAGIC) + len(nonce) + len(payload)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
