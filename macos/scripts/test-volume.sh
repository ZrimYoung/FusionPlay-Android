#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" \
  "$REPO/macos/Sources/VolumeInteraction.swift" "$REPO/macos/Tests/VolumeSmoke.swift" \
  -o "$PROJECT/build/volume-smoke"
"$PROJECT/build/volume-smoke"
