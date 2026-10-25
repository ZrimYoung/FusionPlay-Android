#!/bin/bash
source "$(dirname "$0")/env.sh"
TEST_APP="$PROJECT/tmp/artwork-smoke.app"
mkdir -p "$TEST_APP/Contents/MacOS"
cp "$REPO/macos/Info.plist" "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ArtworkSmoke' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.artwork-smoke' "$TEST_APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework AppKit \
  "$REPO/macos/Sources/ArtworkLoader.swift" "$REPO/macos/Tests/ArtworkSmoke.swift" \
  -o "$TEST_APP/Contents/MacOS/ArtworkSmoke"
"$TEST_APP/Contents/MacOS/ArtworkSmoke" "$PROJECT/tmp"
