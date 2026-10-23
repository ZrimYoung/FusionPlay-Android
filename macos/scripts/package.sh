#!/bin/bash
source "$(dirname "$0")/env.sh"
PACKAGE="$PROJECT/build/package/FusionPlay-Mac"
mkdir -p "$PACKAGE/source" "$PACKAGE/artifacts"
# Archive the recorded source revision so the binary is delivered with source.
git -C "$REPO" archive HEAD | tar -x -C "$PACKAGE/source"
ditto "$PROJECT/artifacts/FusionPlay Mac.app" "$PACKAGE/artifacts/FusionPlay Mac.app"
printf 'fusionplay-mac-v1\n' > "$PACKAGE/.fusionplay-mac"
FUSIONPLAY_PROJECT_ROOT="$PACKAGE" bash "$REPO/macos/scripts/install-entries.sh"
cp "$REPO/macos/README.md" "$PACKAGE/使用说明.md"
ditto -c -k --keepParent "$PACKAGE" "$PROJECT/artifacts/FusionPlay-Mac-arm64.zip"
