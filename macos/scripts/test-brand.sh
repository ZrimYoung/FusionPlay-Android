#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework AppKit -framework SwiftUI \
  "$REPO/macos/Sources/AppBrand.swift" "$REPO/macos/Tests/BrandSmoke.swift" \
  -o "$PROJECT/build/brand-smoke"
"$PROJECT/build/brand-smoke" "$PROJECT"
