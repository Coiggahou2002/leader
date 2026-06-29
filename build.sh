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

echo "→ assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend"
cp "$BIN/Leader" "$APP/Contents/MacOS/Leader"
cp "$ASSET/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for f in config.py scan.py launch.py archive.py pin.py name.py; do
  cp "$SRC/$f" "$APP/Contents/Resources/backend/$f"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Leader</string>
  <key>CFBundleDisplayName</key><string>Leader</string>
  <key>CFBundleIdentifier</key><string>com.leader.app</string>
  <key>CFBundleExecutable</key><string>Leader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" 2>/dev/null || true
rm -rf "$ASSET"
echo "✅ built: $APP"
echo "   安装: cp -R dist/Leader.app ~/Applications/   (然后双击运行)"
