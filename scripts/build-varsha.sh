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
    -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
    "$SRC"/*.swift -o "$APP/Contents/MacOS/Varsha"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/Fluid.metal" "$SRC/Rain.metal" "$APP/Contents/Resources/"
# Ad-hoc signatures default to a cdhash requirement, which changes each build and voids the
# Screen Recording grant. The bundle-ID requirement stays the same across builds.
codesign --force --sign - -r='designated => identifier "local.varsha.Varsha"' "$APP"
printf '%s\n' "$APP"
