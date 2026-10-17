#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/Headphone Release.app"
if [[ ! -x "$APP/Contents/MacOS/HeadphoneRelease" ]]; then
  echo "Run ./build.sh first." >&2
  exit 1
fi
"$APP/Contents/MacOS/HeadphoneRelease" --self-test
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"
