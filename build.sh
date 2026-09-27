#!/bin/zsh
# Собирает RayDesk.app рядом со скриптом и подписывает его.
# SIGN_IDENTITY — идентичность codesign; по умолчанию первая «Apple Development»,
# чтобы разрешение на запись экрана не сбрасывалось после каждой пересборки.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=RayDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/RayDesk "$APP/Contents/MacOS/RayDesk"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.raydesk</string>
  <key>CFBundleName</key><string>RayDesk</string>
  <key>CFBundleExecutable</key><string>RayDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>RayDesk показывает виртуальный монитор в очках.</string>
</dict>
</plist>
PLIST

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Готово: $PWD/$APP"
