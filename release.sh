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
PREFIX="https://github.com/$REPO/releases/latest/download/"
if [ -n "$SPARKLE_ED_PRIVATE_KEY" ]; then
  # CI: key comes from a secret via stdin (never written to disk).
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GA" --ed-key-file - --download-url-prefix "$PREFIX" "$REL"
else
  # Local: key is read from the login keychain.
  "$GA" --download-url-prefix "$PREFIX" "$REL"
fi

echo "→ generate changelog"
# Commits since the previous v* tag, bucketed by conventional-commit prefix. Needs
# full history + tags (CI checkout uses fetch-depth: 0). CUR_TAG is excluded so this
# works whether or not the tag exists locally yet (tag-push CI has it; a local run
# before tagging doesn't — either way PREV_TAG is the prior release).
CUR_TAG="$TAG"
PREV_TAG="$(git tag --list 'v*' --sort=-version:refname | grep -vx "$CUR_TAG" | head -1 || true)"
RANGE="HEAD"; [ -n "$PREV_TAG" ] && RANGE="$PREV_TAG..HEAD"
echo "  range: ${PREV_TAG:-(root)}..$CUR_TAG"

feats="$(git log $RANGE --no-merges -E --grep '^feat(\(.*\))?!?:' --pretty='- %s (`%h`)')"
fixes="$(git log $RANGE --no-merges -E --grep '^fix(\(.*\))?!?:'  --pretty='- %s (`%h`)')"
others="$(git log $RANGE --no-merges -E --invert-grep \
            --grep '^feat(\(.*\))?!?:' --grep '^fix(\(.*\))?!?:' --grep '^chore: bump VERSION' \
            --pretty='- %s (`%h`)')"
allc="$(git log $RANGE --no-merges --pretty='- `%h` %s')"

NOTES="$REL/notes.md"
{
  [ -n "$feats" ]  && printf '### ✨ 新增功能\n%s\n\n' "$feats"
  [ -n "$fixes" ]  && printf '### 🐛 修复\n%s\n\n' "$fixes"
  [ -n "$others" ] && printf '### 🔧 其他变更\n%s\n\n' "$others"
  printf '### 📦 包含的提交\n%s\n\n' "${allc:-- (无新提交)}"
  [ -n "$PREV_TAG" ] && printf '**Full changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREV_TAG" "$CUR_TAG"
} > "$NOTES"

echo "→ publish GitHub release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" "$REL/appcast.xml" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "Leader $VERSION" --notes-file "$NOTES"
else
  gh release create "$TAG" "$ZIP" "$REL/appcast.xml" \
    --repo "$REPO" --title "Leader $VERSION" --notes-file "$NOTES"
fi
echo "✅ released $TAG"
echo "   feed: https://github.com/$REPO/releases/latest/download/appcast.xml"
