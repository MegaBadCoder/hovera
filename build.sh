#!/bin/zsh
# Собирает RayDesk.app в /Applications и подписывает его.
# APP_BUNDLE — путь установки, по умолчанию /Applications/RayDesk.app.
# SIGN_IDENTITY — идентичность codesign; по умолчанию первая «Apple Development»,
# чтобы разрешение на запись экрана не сбрасывалось после каждой пересборки.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=${APP_BUNDLE:-/Applications/RayDesk.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/RayDesk "$APP/Contents/MacOS/RayDesk"
mkdir -p "$APP/Contents/Resources"
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
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>RayDesk shows a virtual monitor in the glasses.</string>
  <key>NSCameraUsageDescription</key><string>RayDesk tells from the camera where your head is, so the screens stay in place. Frames are not saved.</string>
</dict>
</plist>
PLIST

# Тексты разрешений система берёт из своей локализации, а не из выбранного в приложении языка.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/ru.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"NSScreenCaptureUsageDescription" = "RayDesk shows a virtual monitor in the glasses.";
"NSCameraUsageDescription" = "RayDesk tells from the camera where your head is, so the screens stay in place. Frames are not saved.";
STRINGS
cat > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings" <<STRINGS
"NSScreenCaptureUsageDescription" = "RayDesk показывает виртуальный монитор в очках.";
"NSCameraUsageDescription" = "RayDesk оценивает по камере, где голова, чтобы экраны держались на месте. Кадры не сохраняются.";
STRINGS

# Отпечаток исходников включает незакоммиченные изменения, а не только commit.
APP_BUNDLE="$APP" python3 - <<'BUILDINFO'
import datetime, hashlib, os, pathlib, plistlib, subprocess
root = pathlib.Path.cwd()
h = hashlib.sha256()
for path in sorted([*(p for p in root.glob('Sources/**/*') if p.is_file() and p.suffix in {'.swift', '.c', '.h', '.txt'}), root / 'Package.swift', root / 'build.sh']):
    h.update(str(path.relative_to(root)).encode())
    h.update(path.read_bytes())
path = pathlib.Path(os.environ['APP_BUNDLE']) / 'Contents/Info.plist'
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
echo "Готово: $APP"
