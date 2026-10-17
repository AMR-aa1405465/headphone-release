#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/Headphone Release.app"
ARCH="${TARGET_ARCH:-$(uname -m)}"
if [[ "$ARCH" != arm64 && "$ARCH" != x86_64 ]]; then
  echo "TARGET_ARCH must be arm64 or x86_64" >&2; exit 1
fi
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx14.2" Sources/main.swift -o "$APP/Contents/MacOS/HeadphoneRelease" -framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HeadphoneRelease</string>
<key>CFBundleIdentifier</key><string>local.prototype.HeadphoneRelease</string>
<key>CFBundleName</key><string>Headphone Release</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSAudioCaptureUsageDescription</key><string>Measure system audio levels locally to release Bluetooth headphones during silence. Audio is not recorded or uploaded.</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
