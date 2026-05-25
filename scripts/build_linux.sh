#!/usr/bin/env bash
# Build SeeDesktop .deb on Ubuntu/Debian (Flutter + Rust).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEB_ARCH="${DEB_ARCH:-amd64}"

if [[ -z "${VCPKG_ROOT:-}" && -d "${ROOT}/vcpkg" ]]; then
  export VCPKG_ROOT="${ROOT}/vcpkg"
fi

echo "==> SeeDesktop Linux build (arch=$DEB_ARCH)"
echo "    Requires: Rust, Flutter, vcpkg (VCPKG_ROOT), build deps from .github/workflows/bridge.yml"

if ! command -v flutter >/dev/null 2>&1; then
  echo "ERROR: flutter not found on PATH" >&2
  exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found on PATH" >&2
  exit 1
fi

python3 build.py --flutter "$@"

VERSION="$(python3 -c "import re; print(re.search(r'^version\s*=\s*\"([^\"]+)\"', open('Cargo.toml', encoding='utf-8').read(), re.M).group(1))")"
OUT="SeeDesktop-${VERSION}-${DEB_ARCH}.deb"
if [[ -f "$OUT" ]]; then
  echo "==> Built: $ROOT/$OUT"
  ls -lh "$OUT"
else
  echo "ERROR: expected output not found: $OUT" >&2
  exit 1
fi
