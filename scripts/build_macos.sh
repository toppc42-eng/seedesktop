#!/usr/bin/env bash
# Build SeeDesktop.app and optional DMG on macOS (run on a Mac host, not Windows).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> SeeDesktop macOS build (repo: $ROOT)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: This script must run on macOS." >&2
  exit 1
fi

EXTRA_ARGS=()
if [[ "${SEEDESKTOP_HWCODEC:-}" == "1" ]]; then
  EXTRA_ARGS+=(--hwcodec)
fi
if [[ "${SEEDESKTOP_SCREENCAPTUREKIT:-}" == "1" ]]; then
  EXTRA_ARGS+=(--screencapturekit)
fi

python3 build.py --flutter "${EXTRA_ARGS[@]}"

VERSION="$(python3 -c "import re; print(re.search(r'^version\\s*=\\s*\"([^\"]+)\"', open('Cargo.toml', encoding='utf-8').read(), re.M).group(1))")"
APP="flutter/build/macos/Build/Products/Release/SeeDesktop.app"
DMG="SeeDesktop-${VERSION}-macOS.dmg"

echo ""
echo "Build complete."
echo "  App bundle: $ROOT/$APP"
if [[ -f "$ROOT/$DMG" ]]; then
  echo "  DMG:        $ROOT/$DMG"
else
  echo "  DMG:        (skipped — set SEEDESKTOP_SKIP_DMG=1 to skip, or install create-dmg)"
fi
echo ""
echo "Optional signing: export P='Developer ID Application: Your Name (TEAMID)'"
echo "Optional notarization: rcodesign notary-submit --api-key-path ../.p12/api-key.json --staple $DMG"
echo "Publish to GCS: python3 publish_update_mac.py"
