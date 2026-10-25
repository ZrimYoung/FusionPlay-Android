#!/bin/bash
source "$(dirname "$0")/env.sh"
cd "$REPO"
HOST_MANIFEST="$REPO/src/FusionPlay.Host/Cargo.toml"
cargo build --locked --release --manifest-path "$HOST_MANIFEST"
GENERATED="$PROJECT/build/bindings"
mkdir -p "$GENERATED" "$PROJECT/cache/swift"
(cd "$REPO/src/FusionPlay.Host" && "$CARGO_TARGET_DIR/release/fusionplay-bindgen" generate --library "$CARGO_TARGET_DIR/release/libfusionplay_host.dylib" --language swift --config "$REPO/src/FusionPlay.Host/uniffi.toml" --out-dir "$GENERATED")
APP="$PROJECT/artifacts/FusionPlay Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$REPO/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$CARGO_TARGET_DIR/release/libfusionplay_host.dylib" "$APP/Contents/Frameworks/"
install_name_tool -id '@rpath/libfusionplay_host.dylib' "$APP/Contents/Frameworks/libfusionplay_host.dylib"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" \
  -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$APP/Contents/Frameworks" -lfusionplay_host \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -framework SwiftUI -framework AppKit -framework MediaPlayer \
  "$GENERATED/FusionPlayBridge.swift" "$REPO"/macos/Sources/*.swift \
  -o "$APP/Contents/MacOS/FusionPlayMac"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE"
bash "$REPO/macos/scripts/build-icon.sh" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/Frameworks/libfusionplay_host.dylib"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'fusionplay-mac-v1\n' > "$PROJECT/.fusionplay-mac"
printf '%s\n' "$APP"
