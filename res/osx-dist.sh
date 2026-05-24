#!/usr/bin/env bash

echo $MACOS_CODESIGN_IDENTITY
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid
cd flutter; flutter pub get; cd -
~/.cargo/bin/flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
./build.py --flutter
VERSION="$(python3 -c "import re; print(re.search(r'^version\s*=\s*\"([^\"]+)\"', open('Cargo.toml', encoding='utf-8').read(), re.M).group(1))")"
rm -f "SeeDesktop-${VERSION}-macOS.dmg"
# security find-identity -v
codesign --force --options runtime -s $MACOS_CODESIGN_IDENTITY --deep --strict ./flutter/build/macos/Build/Products/Release/SeeDesktop.app -vvv
create-dmg --icon "SeeDesktop.app" 200 190 --hide-extension "SeeDesktop.app" --window-size 800 400 --app-drop-link 600 185 "SeeDesktop-${VERSION}-macOS.dmg" ./flutter/build/macos/Build/Products/Release/SeeDesktop.app
codesign --force --options runtime -s $MACOS_CODESIGN_IDENTITY --deep --strict "SeeDesktop-${VERSION}-macOS.dmg" -vvv
rcodesign notary-submit --api-key-path ~/.p12/api-key.json --staple "SeeDesktop-${VERSION}-macOS.dmg"
