#!/bin/bash
# Builds Insomnimac.app, installs it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Insomnimac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/Insomnimac" Sources/main.swift \
  -framework AppKit -framework IOKit -framework ServiceManagement
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Insomnimac</string>
  <key>CFBundleDisplayName</key><string>Insomnimac</string>
  <key>CFBundleIdentifier</key><string>com.local.insomnimac</string>
  <key>CFBundleExecutable</key><string>Insomnimac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

DEST=/Applications/Insomnimac.app

# Quit any running instance (its quit handler restores normal sleep).
if pgrep -xq Insomnimac; then
  osascript -e 'quit app "Insomnimac"' 2>/dev/null || pkill -x Insomnimac || true
  for _ in {1..20}; do pgrep -xq Insomnimac || break; sleep 0.25; done
  pkill -9 -x Insomnimac 2>/dev/null || true
fi

rm -rf "$DEST"
ditto build/Insomnimac.app "$DEST"
for _ in 1 2 3 4 5; do open "$DEST" 2>/dev/null && break; sleep 1; done
echo "Installed to $DEST and launched."
