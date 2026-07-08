#!/bin/zsh
# Cut a Leader release: build the app, zip it, (re)generate the EdDSA-signed
# Sparkle appcast, and publish both to a GitHub Release.
#
#   1. bump ./VERSION   (Sparkle compares CFBundleVersion — must increase)
#   2. ./release.sh
#
# The appcast is signed with the EdDSA private key in your login keychain
# (created once by Sparkle's generate_keys; public half is baked into the app
# via build.sh's SUPublicEDKey). SUFeedURL points at the "latest" release asset,
# so shipping a newer release is all a running app needs to see the update.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
REPO="Coiggahou2002/leader"
TAG="v$VERSION"
REL="$ROOT/dist/releases"

echo "→ build v$VERSION"
"$ROOT/build.sh"

echo "→ package Leader-$VERSION.zip"
mkdir -p "$REL"
ZIP="$REL/Leader-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/Leader.app" "$ZIP"

echo "→ (re)generate signed appcast"
GA="$(find "$ROOT/.build/artifacts" -type f -name generate_appcast 2>/dev/null | head -1)"
[ -z "$GA" ] && { echo "✗ generate_appcast not found — run ./build.sh first"; exit 1; }
# Enclosure URLs resolve to whatever the *latest* release attaches, matching SUFeedURL.
"$GA" --download-url-prefix "https://github.com/$REPO/releases/latest/download/" "$REL"

echo "→ publish GitHub release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" "$REL/appcast.xml" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$ZIP" "$REL/appcast.xml" \
    --repo "$REPO" --title "Leader $VERSION" --notes "Leader $VERSION"
fi
echo "✅ released $TAG"
echo "   feed: https://github.com/$REPO/releases/latest/download/appcast.xml"
