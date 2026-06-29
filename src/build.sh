#!/bin/zsh
# 编译原生 LeaderApp.swift → ~/Applications/Leader.app
set -e
DIR="$HOME/.claude/skills/leader"
APP="$HOME/Applications/Leader.app"

echo "→ 编译 (swiftc)…"
swiftc -O -swift-version 5 -parse-as-library -framework SwiftUI -framework AppKit \
  "$DIR/LeaderApp.swift" -o "$DIR/Leader.bin"

echo "→ 组装 app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Leader.bin" "$APP/Contents/MacOS/Leader"
[ -f "$DIR/AppIcon.icns" ] && cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Leader</string>
  <key>CFBundleDisplayName</key><string>Leader</string>
  <key>CFBundleIdentifier</key><string>dev.rory.leader</string>
  <key>CFBundleExecutable</key><string>Leader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "✅ $APP"
