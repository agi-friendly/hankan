#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
APP="${SCREEN_TRANSLATE_APP:-$PWD/build/한칸.app}"
CACHE="${SCREEN_TRANSLATE_CACHE:-$PWD/build/swift-module-cache}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "${SCREEN_TRANSLATE_PREVIEW:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.geumcha.screen-translate.preview' "$APP/Contents/Info.plist"
fi
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$CACHE" \
  -framework AppKit -framework Vision -framework ScreenCaptureKit -framework ImageIO -framework NaturalLanguage \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/ScreenTranslate"
/usr/bin/codesign --force --deep --sign - "$APP"
