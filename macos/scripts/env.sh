#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
if [[ -z "${RUSTUP_HOME:-}" && -d "$(dirname "$PROJECT")/FusionPlay/tools/rust/rustup" ]]; then
  export RUSTUP_HOME="$(dirname "$PROJECT")/FusionPlay/tools/rust/rustup"
  export PATH="$(dirname "$PROJECT")/FusionPlay/tools/rust/cargo/bin:$PATH"
fi
export CARGO_HOME="$PROJECT/cache/cargo"
export CARGO_TARGET_DIR="$PROJECT/build/rust"
export MACOSX_DEPLOYMENT_TARGET=14.0
export TMPDIR="$PROJECT/tmp/"
mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR" "$PROJECT/artifacts" "$PROJECT/data" "$PROJECT/logs" "$TMPDIR"
umask 077
