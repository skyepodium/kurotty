#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:?usage: verify-release-artifact.sh <dmg-path> <expected-version>}"
EXPECTED_VERSION="${2:?usage: verify-release-artifact.sh <dmg-path> <expected-version>}"
REQUIRE_NOTARIZATION="${KUROTTY_REQUIRE_NOTARIZATION:-0}"

[[ -f "$DMG_PATH" ]] || { echo "release artifact verification failed: missing DMG: $DMG_PATH" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kurotty-release-verify.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mount"
COPIED_APP="$WORK_DIR/isolated/kurotty.app"
mounted=0

cleanup() {
  if [[ "$mounted" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$MOUNT_DIR" "$(dirname "$COPIED_APP")"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
mounted=1

[[ -d "$MOUNT_DIR/kurotty.app" ]] || { echo "release artifact verification failed: DMG has no kurotty.app" >&2; exit 1; }
[[ -L "$MOUNT_DIR/Applications" && "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] || {
  echo "release artifact verification failed: DMG has no Applications -> /Applications symlink" >&2
  exit 1
}

ditto "$MOUNT_DIR/kurotty.app" "$COPIED_APP"
hdiutil detach "$MOUNT_DIR" >/dev/null
mounted=0

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$COPIED_APP/Contents/Info.plist")"
[[ "$actual_version" == "$EXPECTED_VERSION" ]] || {
  echo "release artifact verification failed: expected version $EXPECTED_VERSION, got $actual_version" >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$COPIED_APP"
lipo "$COPIED_APP/Contents/MacOS/kurotty" -verify_arch arm64 x86_64
lipo "$COPIED_APP/Contents/Resources/libkurotty_core.dylib" -verify_arch arm64 x86_64
"$COPIED_APP/Contents/MacOS/kurotty" --release-artifact-smoke-test

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl -a -vvv -t exec "$COPIED_APP"
fi

echo "release artifact verification passed: $DMG_PATH"
