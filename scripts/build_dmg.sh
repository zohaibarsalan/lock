#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_metadata.sh"

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
STAGING_DIR="$ROOT_DIR/dist/dmg-staging"
RELEASE_DIR="$ROOT_DIR/dist/release"
DMG_NAME="$APP_NAME-$APP_VERSION.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
VOLUME_NAME="$APP_NAME $APP_VERSION"

cd "$ROOT_DIR"
./scripts/build_app.sh

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$RELEASE_DIR"

ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

echo "Built DMG at: $DMG_PATH"
echo "SHA-256 checksum: $CHECKSUM_PATH"
