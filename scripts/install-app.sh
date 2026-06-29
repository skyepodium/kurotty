#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="kurotty"
VERSION_FILE="$ROOT_DIR/VERSION"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
APP_BUNDLE="$ROOT_DIR/.build/${APP_NAME}.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/${APP_NAME}.app"
RESOURCE_BUNDLE="Kurotty_KurottyApp.bundle"
ICONSET_DIR="$APP_BUNDLE/Contents/Resources/kurotty.iconset"

source "$ROOT_DIR/scripts/iconset.sh"

cd "$ROOT_DIR"

swift build -c release
zig build -Doptimize=ReleaseFast
BUILD_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/kurotty" "$APP_BUNDLE/Contents/MacOS/kurotty"
cp -R "$BUILD_DIR/$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE"
cp "$ROOT_DIR/zig-out/lib/libkurotty_core.dylib" "$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib"

create_kurotty_iconset "$ROOT_DIR/kurotty.png" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/kurotty.icns"
rm -rf "$ICONSET_DIR"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>kurotty</string>
  <key>CFBundleIconFile</key>
  <string>kurotty.icns</string>
  <key>CFBundleIdentifier</key>
  <string>dev.kurotty.app</string>
  <key>CFBundleName</key>
  <string>kurotty</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>local</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

# Sign the completed bundle, not just the Swift-built executable. UserNotifications
# relies on macOS resolving the app identity from the final .app bundle.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Install directory does not exist: $INSTALL_DIR" >&2
  exit 1
fi

rm -rf "$INSTALLED_APP"
cp -R "$APP_BUNDLE" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
touch "$INSTALLED_APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

"$ROOT_DIR/scripts/verify-icon-bundle.sh" "$INSTALLED_APP"

echo "Installed $INSTALLED_APP"
echo "Open it with: open '$INSTALLED_APP'"
