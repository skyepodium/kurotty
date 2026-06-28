#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0-alpha.1}"

case "$VERSION" in
  v*) VERSION="${VERSION#v}" ;;
esac

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$ROOT_DIR/.build/release-staging"
APP_NAME="kurotty"
APP_BUNDLE="$STAGING_DIR/${APP_NAME}.app"
ZIP_NAME="kurotty-$VERSION-macos.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

cd "$ROOT_DIR"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"

INSTALL_DIR="$STAGING_DIR" "$ROOT_DIR/scripts/install-app.sh" >/dev/null
"$ROOT_DIR/scripts/verify-icon-bundle.sh" "$APP_BUNDLE"

rm -f "$ZIP_PATH" "$DIST_DIR/SHA256SUMS"
(
  cd "$STAGING_DIR"
  ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_PATH"
)

(
  cd "$DIST_DIR"
  shasum -a 256 "$ZIP_NAME" > SHA256SUMS
)

echo "Packaged $ZIP_PATH"
echo "Wrote $DIST_DIR/SHA256SUMS"
