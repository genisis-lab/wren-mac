#!/bin/sh
# Build Wren.app (needs macOS 14 or later and Xcode 16 or later).
#   ./bundle.sh                                              signed for this Mac only
#   SIGN_IDENTITY="Developer ID Application: …" ./bundle.sh  signed to share (then notarize; see README.md)
#   CONFIG=debug ./bundle.sh                                 a debug build (the screenshot run uses one)
set -eu
cd "$(dirname "$0")"
CONFIG="${CONFIG:-release}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Wren"
APP=build/Wren.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Wren"
cp Info.plist "$APP/Contents/Info.plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
