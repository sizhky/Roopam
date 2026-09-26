#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Roopam"
OUT="$ROOT/build-local"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos26.0"
sources=( "$SRC"/Models/*.swift "$SRC"/Services/*.swift "$SRC"/Views/*.swift )
xcrun swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" -module-name RecoveryChecks \
    -import-objc-header "$SRC/Roopam-Bridging-Header.h" \
    -framework Cocoa -framework CoreServices -framework ServiceManagement \
    "${sources[@]}" "$ROOT/tests/RecoveryChecks.swift" "$OUT"/objects/*.o -o "$OUT/RecoveryChecks"
"$OUT/RecoveryChecks"
