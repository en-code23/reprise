#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="${VERSION:-1.3.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Reprise.app"

rm -rf "$APP_DIR" "$DIST_DIR/dmg-root"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR/dmg-root"

swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT_DIR/macos"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT_DIR/macos" --show-bin-path)"
ICON_PATH="$($ROOT_DIR/scripts/make-icon.sh)"

cp "$BIN_DIR/Reprise" "$APP_DIR/Contents/MacOS/Reprise"
cp "$ROOT_DIR/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP_DIR/Contents/Info.plist"

xattr -cr "$APP_DIR"
codesign --force --deep --options runtime --entitlements "$ROOT_DIR/macos/Reprise.entitlements" --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/Reprise-$VERSION-macOS.zip"

cp -R "$APP_DIR" "$DIST_DIR/dmg-root/Reprise.app"
ln -s /Applications "$DIST_DIR/dmg-root/Applications"
hdiutil create \
  -volname "Reprise" \
  -srcfolder "$DIST_DIR/dmg-root" \
  -ov \
  -format UDZO \
  "$DIST_DIR/Reprise-$VERSION-macOS.dmg" >/dev/null

rm -rf "$DIST_DIR/dmg-root"
echo "Built $DIST_DIR/Reprise-$VERSION-macOS.dmg"
