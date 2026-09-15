#!/bin/bash
# Builds Screen2Prompt.app — a hand-assembled bundle, because there is no full Xcode here.
set -e
cd "$(dirname "$0")"

APP="Screen2Prompt.app"
swift build -c release --product Screen2Prompt

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Screen2Prompt "$APP/Contents/MacOS/Screen2Prompt"

if [ ! -f tools/AppIcon.icns ]; then
  swift tools/make-icon.swift tools >/dev/null 2>&1
  iconutil -c icns tools/AppIcon.iconset -o tools/AppIcon.icns
  rm -rf tools/AppIcon.iconset
fi
cp tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                <string>Screen2Prompt</string>
  <key>CFBundleDisplayName</key>         <string>Screen2Prompt</string>
  <key>CFBundleIdentifier</key>          <string>co.ema.screen2prompt</string>
  <key>CFBundleExecutable</key>          <string>Screen2Prompt</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>CFBundleShortVersionString</key>  <string>0.0.1</string>
  <key>CFBundleVersion</key>             <string>1</string>
  <key>LSMinimumSystemVersion</key>      <string>13.0</string>
  <key>CFBundleIconFile</key>            <string>AppIcon</string>
  <key>LSUIElement</key>                 <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Screen2Prompt records your narration while you work.</string>
</dict>
</plist>
PLIST

codesign -s - --force --timestamp=none "$APP" >/dev/null 2>&1 || true
echo "built $(pwd)/$APP  ($(du -h "$APP/Contents/MacOS/Screen2Prompt" | cut -f1) binary)"
