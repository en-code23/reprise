#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="${VERSION:-1.9.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reprise-release.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Reprise.app"
DMG_ROOT="$STAGING_DIR/dmg-root"

# Build outside cloud-synced folders, which can add Finder metadata mid-signing.
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DMG_ROOT" "$DIST_DIR"

swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT_DIR/macos"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT_DIR/macos" --show-bin-path)"
ICON_PATH="$($ROOT_DIR/scripts/make-icon.sh)"

cp "$BIN_DIR/Reprise" "$APP_DIR/Contents/MacOS/Reprise"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  MACOSX_DEPLOYMENT_TARGET=14.0 "${CARGO:-cargo}" build --locked --release --manifest-path "$ROOT_DIR/runner/Cargo.toml" --target "$target"
done
lipo -create "$ROOT_DIR/runner/target/aarch64-apple-darwin/release/reprise-agent" "$ROOT_DIR/runner/target/x86_64-apple-darwin/release/reprise-agent" -output "$APP_DIR/Contents/MacOS/reprise-agent"
python3 "$ROOT_DIR/scripts/runner-licenses.py" "$APP_DIR/Contents/Resources/runner-licenses"
cp "$ROOT_DIR/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
mkdir -p "$APP_DIR/Contents/Frameworks"
SPARKLE_SOURCE="$ROOT_DIR/macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
cp "$ROOT_DIR/macos/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist"

xattr -cr "$APP_DIR"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/reprise-agent"
# Sign nested Sparkle code inside-out without applying the app's entitlements
# to Sparkle's installer, downloader, or XPC services.
SPARKLE_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
for component in "$SPARKLE_DIR/XPCServices/Downloader.xpc" "$SPARKLE_DIR/XPCServices/Installer.xpc" "$SPARKLE_DIR/Autoupdate" "$SPARKLE_DIR/Updater.app" "$APP_DIR/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$component"
done
codesign --force --options runtime --entitlements "$ROOT_DIR/macos/Reprise.entitlements" --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/Reprise-$VERSION-macOS.zip"

ditto "$APP_DIR" "$DMG_ROOT/Reprise.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname "Reprise" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DIST_DIR/Reprise-$VERSION-macOS.dmg" >/dev/null

rm -rf "$DIST_DIR/Reprise.app"
ditto "$APP_DIR" "$DIST_DIR/Reprise.app"
xattr -cr "$DIST_DIR/Reprise.app"
echo "Built $DIST_DIR/Reprise-$VERSION-macOS.dmg"
