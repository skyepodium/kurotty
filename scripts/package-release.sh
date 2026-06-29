#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
VERSION="${1:-$(tr -d '[:space:]' < "$VERSION_FILE")}"

case "$VERSION" in
  v*) VERSION="${VERSION#v}" ;;
esac

APP_NAME="kurotty"
APP_DISPLAY_NAME="Kurotty"
APP_BUNDLE_ID="dev.kurotty.app"
RESOURCE_BUNDLE="Kurotty_KurottyApp.bundle"
BUILD_ARCHES=(arm64 x86_64)
KEEP_WORKDIR="${KUROTTY_KEEP_RELEASE_WORKDIR:-0}"
STRIP_TOOL="${STRIP_TOOL:-strip}"

DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/.build/release-package"
APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
DMG_ROOT="$WORK_DIR/dmg-root"
DMG_RW="$WORK_DIR/$APP_NAME-rw.dmg"
DMG_NAME="kurotty-$VERSION-macos-universal.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
DMG_LATEST_NAME="kurotty-macos-universal.dmg"
DMG_LATEST_PATH="$DIST_DIR/$DMG_LATEST_NAME"
ICONSET_DIR="$WORK_DIR/kurotty.iconset"

SIGN_IDENTITY="${KUROTTY_RELEASE_SIGN_IDENTITY:-${SIGN_IDENTITY:--}}"
NOTARY_PROFILE="${KUROTTY_NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${KUROTTY_NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${KUROTTY_NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${KUROTTY_NOTARY_PASSWORD:-}"
SPARKLE_FEED_URL="${KUROTTY_SPARKLE_FEED_URL:-https://github.com/skyepodium/kurotty/releases/latest/download/appcast.xml}"
: "${KUROTTY_SPARKLE_PUBLIC_KEY:?KUROTTY_SPARKLE_PUBLIC_KEY is required for Sparkle updates}"
SPARKLE_PUBLIC_KEY="$KUROTTY_SPARKLE_PUBLIC_KEY"
SPARKLE_TOOLS_DERIVED_DATA="$WORK_DIR/sparkle-tools"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$SPARKLE_TOOLS_DERIVED_DATA/Build/Products/Release/generate_appcast}"

source "$ROOT_DIR/scripts/iconset.sh"

cd "$ROOT_DIR"

rm -rf "$WORK_DIR"
mkdir -p "$DIST_DIR" "$WORK_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

swift_binary_paths=()
zig_dylib_paths=()

for arch in "${BUILD_ARCHES[@]}"; do
  case "$arch" in
    arm64)
      triple="arm64-apple-macosx14.0"
      zig_target="aarch64-macos"
      ;;
    x86_64)
      triple="x86_64-apple-macosx14.0"
      zig_target="x86_64-macos"
      ;;
    *)
      echo "unsupported release architecture: $arch" >&2
      exit 1
      ;;
  esac

  scratch_path="$WORK_DIR/swift-$arch"
  zig_prefix="$WORK_DIR/zig-$arch"

  swift build -c release --triple "$triple" --scratch-path "$scratch_path"
  swift_bin_path="$(swift build -c release --triple "$triple" --scratch-path "$scratch_path" --show-bin-path)"
  swift_binary_paths+=("$swift_bin_path/kurotty")

  zig build -Dtarget="$zig_target" -Doptimize=ReleaseFast --prefix "$zig_prefix"
  "$STRIP_TOOL" -x "$zig_prefix/lib/libkurotty_core.dylib"
  zig_dylib_paths+=("$zig_prefix/lib/libkurotty_core.dylib")

  if [[ "$arch" == "arm64" ]]; then
    cp -R "$swift_bin_path/$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE"
    cp -R "$swift_bin_path/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  fi
done

lipo -create "${swift_binary_paths[@]}" -output "$APP_BUNDLE/Contents/MacOS/kurotty"
"$STRIP_TOOL" -x "$APP_BUNDLE/Contents/MacOS/kurotty"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/kurotty"
lipo -info "$APP_BUNDLE/Contents/MacOS/kurotty"

lipo -create "${zig_dylib_paths[@]}" -output "$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib"
"$STRIP_TOOL" -x "$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib"
lipo -info "$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib"

create_kurotty_iconset "$ROOT_DIR/kurotty.png" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/kurotty.icns"

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
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>${GITHUB_RUN_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_BUNDLE"
else
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

"$ROOT_DIR/scripts/verify-icon-bundle.sh" "$APP_BUNDLE"
lipo "$APP_BUNDLE/Contents/MacOS/kurotty" -verify_arch arm64 x86_64
lipo "$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib" -verify_arch arm64 x86_64

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

rm -rf "$DMG_ROOT" "$DMG_RW" "$DMG_PATH" "$DMG_LATEST_PATH" "$DIST_DIR/SHA256SUMS"
mkdir -p "$DMG_ROOT"
cp -R "$APP_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDRW "$DMG_RW" >/dev/null
attach_output="$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen)"
device="$(printf '%s\n' "$attach_output" | awk '/\/Volumes\// { print $1; exit }')"
if [[ -n "$device" ]]; then
  hdiutil detach "$device" >/dev/null
fi
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
elif [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$NOTARY_APPLE_ID" \
    --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
else
  echo "Skipping notarization: set KUROTTY_NOTARY_PROFILE or Apple ID notarization env vars."
fi

cp "$DMG_PATH" "$DMG_LATEST_PATH"

(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" "$DMG_LATEST_NAME" > SHA256SUMS
)

if [[ -x "$SPARKLE_GENERATE_APPCAST" ]]; then
  "$SPARKLE_GENERATE_APPCAST" "$DIST_DIR"
else
  xcodebuild -project "$ROOT_DIR/.build/checkouts/Sparkle/Sparkle.xcodeproj" \
    -scheme generate_appcast \
    -configuration Release \
    -derivedDataPath "$SPARKLE_TOOLS_DERIVED_DATA" \
    build
  "$SPARKLE_GENERATE_APPCAST" "$DIST_DIR"
fi

if [[ "$KEEP_WORKDIR" != "1" ]]; then
  rm -rf "$WORK_DIR"/swift-* "$WORK_DIR"/zig-* "$ICONSET_DIR" "$DMG_ROOT" "$DMG_RW"
fi

echo "Packaged $DMG_PATH"
echo "Packaged $DMG_LATEST_PATH"
echo "Wrote $DIST_DIR/SHA256SUMS"
