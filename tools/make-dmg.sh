#!/usr/bin/env bash
# Riftsight.app 을 만들어 dist/Riftsight.dmg 로 묶는다.   bash tools/make-dmg.sh
set -e
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"

swift build -c release
APP=dist/Riftsight.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp .build/release/Riftsight "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Riftsight</string>
  <key>CFBundleIdentifier</key><string>com.starlight0307.riftsight</string>
  <key>CFBundleExecutable</key><string>Riftsight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# 화면 기록 권한이 앱에 붙도록 서명 (애플 개발자 인증서가 없어 임시 서명)
codesign --force --deep -s - "$APP"

mkdir -p dist/dmg && cp -R "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
hdiutil create -volname Riftsight -srcfolder dist/dmg -ov -format UDZO dist/Riftsight.dmg >/dev/null
rm -rf dist/dmg
echo "만듦: dist/Riftsight.dmg"
