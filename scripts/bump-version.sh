#!/bin/bash
# Bumps CFBundleShortVersionString (semver), increments CFBundleVersion,
# and adds an empty CHANGELOG section for the new version.
#
# Usage: scripts/bump-version.sh major|minor|patch|X.Y.Z [plist] [changelog]
#   1.2.2 patch -> 1.2.3, minor -> 1.3.0, major -> 2.0.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PART="${1:?usage: bump-version.sh major|minor|patch|X.Y.Z}"
PLIST="${2:-$ROOT/Roopam/Info.plist}"
CHANGELOG="${3:-$ROOT/CHANGELOG.md}"

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$PART" in
    major) NEXT="$((MAJOR + 1)).0.0" ;;
    minor) NEXT="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEXT="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    *)
        [[ "$PART" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: '$PART' is not major, minor, patch or X.Y.Z" >&2; exit 2; }
        NEXT="$PART" ;;
esac
[ "$NEXT" != "$CURRENT" ] || { echo "error: version is already $CURRENT" >&2; exit 1; }

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"
NIX="$ROOT/nix/default.nix"
[ -z "${2:-}" ] && [ -f "$NIX" ] && sed -i '' -E "s/^  version = \"[0-9.]+\";/  version = \"$NEXT\";/" "$NIX"

if ! grep -q "^## \[$NEXT\]" "$CHANGELOG"; then
    # Insert above the first existing release section.
    awk -v heading="## [$NEXT] - $(date +%Y-%m-%d)" '
        !done && /^## \[/ { print heading "\n\n- \n"; done = 1 }
        { print }
    ' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"
fi
echo "Version $CURRENT -> $NEXT (build $((BUILD + 1))). Fill in the CHANGELOG entry, commit, then run: make release"
