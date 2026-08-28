#!/bin/zsh
# Build a self-contained Leader.app into ./dist (does NOT touch ~/Applications).
# The python backend is bundled inside the app (Contents/Resources/backend),
# so the built app has no dependency on this source tree.
#
# Build is SwiftPM-based (Package.swift) because the app embeds SwiftTerm.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
APP="$ROOT/dist/Leader.app"
ASSET="$ROOT/.assets"          # NOT .build — that belongs to SwiftPM
mkdir -p "$ASSET"

echo "→ icon (makeicon.swift)"
rm -rf "$ASSET/Leader.iconset" "$ASSET/AppIcon.icns"
swift "$SRC/makeicon.swift" "$ASSET/Leader.iconset" >/dev/null
iconutil -c icns "$ASSET/Leader.iconset" -o "$ASSET/AppIcon.icns"

echo "→ compile (swift build -c release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
VERSION="${LEADER_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0)}"   # env (CI tag) wins, else ./VERSION
FEED_URL="https://github.com/Coiggahou2002/leader/releases/latest/download/appcast.xml"
# Sparkle EdDSA public key (private half lives in the keychain; see release.sh).
PUBKEY="m+Oe9QUg09PX7rXOJnc2IEbc/TkXbftv6HN5NmT3w3k="

echo "→ assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend"
cp "$BIN/Leader" "$APP/Contents/MacOS/Leader"
cp "$ASSET/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
[ -e "$ROOT/assets/claude-logo.png" ] && cp "$ROOT/assets/claude-logo.png" "$APP/Contents/Resources/claude-logo.png"
# SwiftPM resource bundles (e.g. SwiftTerm_SwiftTerm.bundle, which carries
# Shaders.metal for the Metal renderer). Bundle.module resolves these from
# Contents/Resources at runtime; without them the Metal path silently falls
# back to CoreGraphics.
for b in "$BIN"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
for f in config.py scan.py launch.py archive.py pin.py name.py unread.py hidden.py leader-hook.py; do
  cp "$SRC/$f" "$APP/Contents/Resources/backend/$f"
done

# Embed Sparkle.framework (in-app auto-update). Prefer the universal copy from
# the xcframework artifact; fall back to the arch-specific staged copy. Then add
# the @executable_path/../Frameworks rpath so the @rpath/Sparkle... link resolves.
echo "→ embed Sparkle.framework"
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' 2>/dev/null | head -1)"
[ -z "$SPARKLE_FW" ] && SPARKLE_FW="$(find "$ROOT/.build" -type d -name Sparkle.framework 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FW" ]; then echo "✗ Sparkle.framework not found under .build"; exit 1; fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
otool -l "$APP/Contents/MacOS/Leader" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Leader"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Leader</string>
  <key>CFBundleDisplayName</key><string>Leader</string>
  <key>CFBundleIdentifier</key><string>com.leader.app</string>
  <key>CFBundleExecutable</key><string>Leader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${PUBKEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict></plist>
PLIST

# Ad-hoc sign inside-out: nested Sparkle helpers first, then the framework, then
# the app (a bundle sign validates — does not create — nested signatures).
echo "→ codesign (ad-hoc)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
for x in "$FW"/Versions/*/XPCServices/*.xpc "$FW"/Versions/*/Autoupdate "$FW"/Versions/*/Updater.app; do
  [ -e "$x" ] && codesign --force --sign - "$x"
done
codesign --force --sign - "$FW"
codesign --force --sign - "$APP"
rm -rf "$ASSET"
echo "✅ built: $APP  (v${VERSION})"
echo "   安装: cp -R dist/Leader.app ~/Applications/   (然后双击运行)"
