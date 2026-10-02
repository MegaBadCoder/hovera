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
mkdir -p "$APP/Contents/Resources"
cp Sources/CAprilTag/LICENSE.md "$APP/Contents/Resources/AprilTag-LICENSE.md"
cp Sources/CAprilTag/UPSTREAM.txt "$APP/Contents/Resources/AprilTag-UPSTREAM.txt"
xcrun coremlcompiler compile Sources/RayDesk/Models/FaceLandmarks.mlpackage "$APP/Contents/Resources" >/dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.raydesk</string>
  <key>CFBundleName</key><string>RayDesk</string>
  <key>CFBundleExecutable</key><string>RayDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>RayDesk показывает виртуальный монитор в очках.</string>
  <key>NSCameraUsageDescription</key><string>RayDesk оценивает по камере, где голова, чтобы экраны держались на месте. Кадры не сохраняются.</string>
</dict>
</plist>
PLIST

# Отпечаток исходников включает незакоммиченные изменения, а не только commit.
python3 - <<'BUILDINFO'
import datetime, hashlib, pathlib, plistlib, subprocess
root = pathlib.Path.cwd()
h = hashlib.sha256()
for path in sorted([*(p for p in root.glob('Sources/**/*') if p.is_file() and p.suffix in {'.swift', '.c', '.h', '.txt'}), root / 'Package.swift', root / 'build.sh']):
    h.update(str(path.relative_to(root)).encode())
    h.update(path.read_bytes())
path = root / 'RayDesk.app/Contents/Info.plist'
with path.open('rb') as file:
    info = plistlib.load(file)
info.update(RayDeskBuildID=h.hexdigest()[:12],
            RayDeskCommit=subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], text=True).strip(),
            RayDeskSource=str(root), RayDeskBuildTime=datetime.datetime.now(datetime.timezone.utc).isoformat())
with path.open('wb') as file:
    plistlib.dump(info, file)
BUILDINFO

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Готово: $PWD/$APP"
