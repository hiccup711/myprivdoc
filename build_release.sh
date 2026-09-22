#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

export VERSION="${VERSION:-0.1.0}"
export APP_DIR=".build/package/PrivDoc.app"
ARCH="$(uname -m)"
DIST_DIR="dist"
ASSET_NAME="PrivDoc-$VERSION-$ARCH"

case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

./build_app.sh
lipo "$APP_DIR/Contents/MacOS/PrivDoc" -verify_arch "$ARCH"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d .build/dmg.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/PrivDoc.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "PrivDoc $VERSION" -srcfolder "$STAGING_DIR" \
  -format UDZO -ov "$DIST_DIR/$ASSET_NAME.dmg"
hdiutil verify "$DIST_DIR/$ASSET_NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/$ASSET_NAME.zip"
unzip -tq "$DIST_DIR/$ASSET_NAME.zip"

(
  cd "$DIST_DIR"
  shasum -a 256 "$ASSET_NAME.dmg" "$ASSET_NAME.zip" > "$ASSET_NAME.sha256"
  shasum -a 256 -c "$ASSET_NAME.sha256"
)

echo "Release assets are in $DIST_DIR/"
