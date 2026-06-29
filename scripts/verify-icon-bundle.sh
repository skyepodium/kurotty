#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-/Applications/kurotty.app}"
ICONSET_CHECK_DIR="$ROOT_DIR/.build/verify-kurotty-icon.iconset"
RESOURCE_BUNDLE="Kurotty_KurottyApp.bundle"

fail() {
  echo "icon verification failed: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

png_dimensions() {
  sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null |
    awk '/pixelWidth/ { width=$2 } /pixelHeight/ { height=$2 } END { print width "x" height }'
}

require_file "$ROOT_DIR/kurotty-profile.png"
require_file "$ROOT_DIR/kurotty.png"
require_file "$ROOT_DIR/Sources/KurottyApp/Resources/kurotty.png"

root_hash="$(shasum -a 256 "$ROOT_DIR/kurotty.png" | awk '{ print $1 }')"
resource_hash="$(shasum -a 256 "$ROOT_DIR/Sources/KurottyApp/Resources/kurotty.png" | awk '{ print $1 }')"
[[ "$root_hash" == "$resource_hash" ]] || fail "kurotty.png and SwiftPM resource PNG differ"

[[ "$(png_dimensions "$ROOT_DIR/kurotty.png")" == "1024x1024" ]] || fail "root kurotty.png must be 1024x1024"
[[ "$(png_dimensions "$ROOT_DIR/Sources/KurottyApp/Resources/kurotty.png")" == "1024x1024" ]] || fail "resource kurotty.png must be 1024x1024"

require_file "$APP_PATH/Contents/Info.plist"
require_file "$APP_PATH/Contents/Resources/$RESOURCE_BUNDLE/kurotty.png"
require_file "$APP_PATH/Contents/Resources/kurotty.icns"

installed_icon_file="$(plutil -extract CFBundleIconFile raw -o - "$APP_PATH/Contents/Info.plist")"
[[ "$installed_icon_file" == "kurotty.icns" ]] || fail "CFBundleIconFile must be kurotty.icns, got $installed_icon_file"

installed_resource_hash="$(shasum -a 256 "$APP_PATH/Contents/Resources/$RESOURCE_BUNDLE/kurotty.png" | awk '{ print $1 }')"
[[ "$installed_resource_hash" == "$root_hash" ]] || fail "installed SwiftPM resource PNG differs from root kurotty.png"

rm -rf "$ICONSET_CHECK_DIR"
iconutil -c iconset "$APP_PATH/Contents/Resources/kurotty.icns" -o "$ICONSET_CHECK_DIR"

required_icons=(
  icon_16x16.png
  icon_16x16@2x.png
  icon_32x32.png
  icon_32x32@2x.png
  icon_128x128.png
  icon_128x128@2x.png
  icon_256x256.png
  icon_256x256@2x.png
  icon_512x512.png
  icon_512x512@2x.png
)

for icon_name in "${required_icons[@]}"; do
  require_file "$ICONSET_CHECK_DIR/$icon_name"
done

if ! rg -q "if !loadedIcon.isInstalledIcon" "$ROOT_DIR/Sources/KurottyApp/AppDelegate.swift"; then
  fail "installed .icns must not be resized through the SwiftPM PNG fallback path"
fi

if ! rg -q "withExtension: AppConstants.Bundle.installedIconExtension" "$ROOT_DIR/Sources/KurottyApp/AppDelegate.swift"; then
  fail "runtime icon loading must prefer installed .icns"
fi

codesign --verify --deep --strict "$APP_PATH"
echo "icon verification passed: $APP_PATH"
