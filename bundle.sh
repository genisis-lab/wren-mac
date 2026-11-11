#!/bin/sh
# Build Wren.app, with its widget and Share extension (needs macOS 14 or later and Xcode 16 or later).
#   ./bundle.sh                                         signed for this Mac only
#   TEAM=ABCDE12345 SIGN_IDENTITY="Apple Development" ./bundle.sh
#                                                       signed with your team, which the widget needs (see README.md)
#   TEAM=ABCDE12345 SIGN_IDENTITY="Developer ID Application" ./bundle.sh
#                                                       signed to share (then notarize; see README.md)
#   CONFIG=debug ./bundle.sh                            a debug build (the screenshot run uses one)
set -eu
cd "$(dirname "$0")"
case "${CONFIG:-release}" in
  debug) CONFIGURATION=Debug ;;
  *) CONFIGURATION=Release ;;
esac

if [ -n "${SIGN_IDENTITY:-}" ]; then
  set -- CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="${TEAM:?Set TEAM to your team ID as well}" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp
else
  set -- CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
fi
xcodebuild -project Wren.xcodeproj -scheme Wren -configuration "$CONFIGURATION" -destination generic/platform=macOS \
  -derivedDataPath build/DerivedData -quiet "$@" build

rm -rf build/Wren.app
cp -R "build/DerivedData/Build/Products/$CONFIGURATION/Wren.app" build/Wren.app
echo "Built build/Wren.app"
