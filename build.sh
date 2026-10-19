#!/bin/bash
# Собирает build/LayoutFixer.app (ad-hoc подпись, только для локального запуска)
set -e
cd "$(dirname "$0")"
APP=build/LayoutFixer.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O Sources/Core.swift Sources/main.swift -o "$APP/Contents/MacOS/LayoutFixer"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LayoutFixer</string>
<key>CFBundleIdentifier</key><string>local.layoutfixer</string>
<key>CFBundleName</key><string>LayoutFixer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PL
# Постоянная подпись сохраняет разрешения между сборками:
# SIGN_ID="LayoutFixer Local Signing" ./build.sh  (иначе ad-hoc, разрешение сбрасывается)
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Готово: $APP"
