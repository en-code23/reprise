#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="${VERSION:-1.5.0}"
ARCHIVE="$ROOT_DIR/dist/Reprise-$VERSION-macOS.zip"
SPARKLE_BIN="$ROOT_DIR/macos/.build/artifacts/sparkle/Sparkle/bin"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reprise-appcast.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  KEY_FILE="$SPARKLE_PRIVATE_KEY_FILE"
else
  : "${SPARKLE_PRIVATE_KEY:?Set the release signing secret or SPARKLE_PRIVATE_KEY_FILE}"
  KEY_FILE="$STAGING_DIR/signing-key"
  umask 077
  printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
fi

cp "$ARCHIVE" "$STAGING_DIR/"
"$SPARKLE_BIN/generate_appcast" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://github.com/en-code23/reprise/releases/download/v$VERSION/" \
  --link "https://en-code23.github.io/reprise/" \
  --maximum-deltas 0 \
  "$STAGING_DIR"
cp "$STAGING_DIR/appcast.xml" "$ROOT_DIR/dist/appcast.xml"
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY_FILE" "$ROOT_DIR/dist/appcast.xml"
swift "$ROOT_DIR/scripts/verify-update.swift" "$ARCHIVE" "$ROOT_DIR/dist/appcast.xml"
echo "Created signed dist/appcast.xml for $VERSION"
