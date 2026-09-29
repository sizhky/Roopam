#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Roopam"
OUT="${BUILD_OUTPUT_DIR:-$ROOT/build-local}"
APP="$OUT/Roopam.app"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos26.0"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/FinderSyncTemplate" "$OUT/objects"
for source in "$SRC"/Services/*.m; do
    xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations -isysroot "$SDK" -target "$TARGET" \
        -c "$source" -o "$OUT/objects/$(basename "$source" .m).o"
done
sources=( "$SRC"/*.swift "$SRC"/Models/*.swift "$SRC"/Services/*.swift "$SRC"/Views/*.swift )
xcrun swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" -module-name Roopam \
    -import-objc-header "$SRC/Roopam-Bridging-Header.h" \
    -framework Cocoa -framework CoreServices -framework ServiceManagement \
    "${sources[@]}" "$OUT"/objects/*.o -o "$APP/Contents/MacOS/Roopam"
xcrun swiftc -sdk "$SDK" -target "$TARGET" -module-name SBFAdvHost \
    "$SRC/FinderSyncTemplate/HostMain.swift" -o "$APP/Contents/Resources/FinderSyncTemplate/host-bin"
xcrun swiftc -sdk "$SDK" -target "$TARGET" -module-name SBFAdvSync \
    -framework FinderSync -framework Cocoa -Xlinker -e -Xlinker _NSExtensionMain \
    "$SRC/FinderSyncTemplate/FinderSyncExt.swift" -o "$APP/Contents/Resources/FinderSyncTemplate/appex-bin"
cp -X "$SRC/Resources/AppIcon.icns" "$SRC/Resources/HelperIcon.icns" "$APP/Contents/Resources/"
python3 - "$SRC/Info.plist" "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
info.update(CFBundleExecutable='Roopam', CFBundleIdentifier='local.roopam.Roopam',
            CFBundleName='Roopam', CFBundleDisplayName='Roopam', LSMinimumSystemVersion='26.0')
with open(sys.argv[2], 'wb') as f: plistlib.dump(info, f)
PY
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
