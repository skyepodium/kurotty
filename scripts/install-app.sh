#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="kurotty"
APP_BUNDLE="$ROOT_DIR/.build/${APP_NAME}.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/${APP_NAME}.app"
RESOURCE_BUNDLE="Kurotty_KurottyApp.bundle"

cd "$ROOT_DIR"

swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/kurotty" "$APP_BUNDLE/Contents/MacOS/kurotty"
cp -R "$BUILD_DIR/$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE"
cp "$ROOT_DIR/kurotty.png" "$APP_BUNDLE/Contents/Resources/kurotty.png"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>kurotty</string>
  <key>CFBundleIconFile</key>
  <string>kurotty</string>
  <key>CFBundleIdentifier</key>
  <string>dev.kurotty.app</string>
  <key>CFBundleName</key>
  <string>kurotty</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Install directory does not exist: $INSTALL_DIR" >&2
  exit 1
fi

rm -rf "$INSTALLED_APP"
cp -R "$APP_BUNDLE" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

echo "Installed $INSTALLED_APP"
echo "Open it with: open '$INSTALLED_APP'"
