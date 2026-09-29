#!/bin/bash
# Builds the standalone Varsha menu bar app into build-varsha/Varsha.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Varsha"
OUT="${BUILD_OUTPUT_DIR:-$ROOT/build-varsha}"
APP="$OUT/Varsha.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos14.0"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -sdk "$SDK" -target "$TARGET" -module-name Varsha \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Metal -framework QuartzCore \
    "$SRC"/*.swift -o "$APP/Contents/MacOS/Varsha"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/Fluid.metal" "$APP/Contents/Resources/Fluid.metal"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
