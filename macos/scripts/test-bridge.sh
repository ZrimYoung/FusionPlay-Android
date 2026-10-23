#!/bin/bash
source "$(dirname "$0")/env.sh"
GENERATED="$PROJECT/build/bindings"
LIBRARY="$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" \
  -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$LIBRARY" -lfusionplay_host -Xlinker -rpath -Xlinker "$LIBRARY" \
  -framework AppKit -framework MediaPlayer \
  "$GENERATED/FusionPlayBridge.swift" "$REPO/macos/Sources/SystemMedia.swift" "$REPO/macos/Tests/BridgeSmoke.swift" \
  -o "$PROJECT/build/bridge-smoke"
"$PROJECT/build/bridge-smoke" "$PROJECT/tmp/bridge-test-$$" "$@"
