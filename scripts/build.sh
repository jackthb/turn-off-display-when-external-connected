#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Panel Off.app"
mkdir -p "$APP/Contents/MacOS" build/module-cache
xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/build/module-cache" \
  -target arm64-apple-macosx13.0 Sources/Policy.swift Sources/AutomationLifecycle.swift Sources/Diagnostics.swift Sources/Displays.swift Sources/PhysicalDisplayWatcher.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/PanelOff" -framework AppKit -framework CoreGraphics -framework ServiceManagement -framework IOKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PanelOff</string>
<key>CFBundleIdentifier</key><string>local.paneloff.app</string>
<key>CFBundleName</key><string>Panel Off</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.4</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
