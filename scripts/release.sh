#!/bin/bash
# Publishes the DMG built by build-release.sh as a GitHub release tagged v<version>.
# Before tagging, it pins the DMG's hash in nix/default.nix and pushes that commit.
# Release notes are the CHANGELOG section for that version.
#
# Preconditions (checked): gh is authenticated, the work tree is clean, HEAD is on
# the release branch and pushed, the tag does not exist, and the CHANGELOG has a
# non-empty section for the version.
#
# Usage: scripts/release.sh [check]   "check" runs the preconditions only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BRANCH="${RELEASE_BRANCH:-main}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Roopam/Info.plist)
TAG="v$VERSION"
DMG="build/DMG/Roopam-$VERSION.dmg"

fail() { echo "error: $*" >&2; exit 1; }
gh auth status > /dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"
[ -z "$(git status --porcelain)" ] || fail "work tree has uncommitted changes"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || fail "releases are cut from '$BRANCH'"
git fetch --quiet origin "$BRANCH"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] || fail "HEAD differs from origin/$BRANCH. Push or pull first."
! git rev-parse -q --verify "refs/tags/$TAG" > /dev/null || fail "tag $TAG already exists. Run: make bump PART=patch"
! git ls-remote --exit-code --tags origin "$TAG" > /dev/null 2>&1 || fail "tag $TAG already exists on origin"

NOTES=$(awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
' CHANGELOG.md)
[ -n "$(echo "$NOTES" | tr -d '[:space:]-')" ] || fail "CHANGELOG.md has no entry for $VERSION"

[ "${1:-}" != "check" ] || { echo "Release $TAG preconditions pass."; exit 0; }
[ -f "$DMG" ] || fail "$DMG not found. Run: make dmg"

# Pin the nix hash before tagging, so the tagged commit installs exactly the uploaded DMG.
bash "$ROOT/scripts/pin-nix-hash.sh" "$DMG.sha256"
if ! git diff --quiet -- nix/default.nix; then
    git commit -q -m "Pin nix hash for $VERSION" -- nix/default.nix
    git push origin "$BRANCH"
fi

git tag -a "$TAG" -m "Roopam $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Roopam $VERSION" --notes "$NOTES" --verify-tag
echo "Published $TAG: $(gh release view "$TAG" --json url -q .url)"
