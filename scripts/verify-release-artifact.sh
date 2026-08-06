#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${1:?usage: verify-release-artifact.sh <dmg-path> <expected-version>}"
EXPECTED_VERSION="${2:?usage: verify-release-artifact.sh <dmg-path> <expected-version>}"
REQUIRE_NOTARIZATION="${KUROTTY_REQUIRE_NOTARIZATION:-0}"

source "$ROOT_DIR/scripts/dmg-style.sh"

# Advisory only, and for the same reason package-release.sh skips styling rather
# than failing: Finder cannot be relied on inside CI, so a DMG that carries the
# app, the symlink, the signature and the right version is still shippable
# without the install-window design. Warn loudly, never exit nonzero.
report_dmg_styling() {
  local mount_dir="$1"
  local background_dir="$mount_dir/$KUROTTY_DMG_BACKGROUND_DIR"
  local settings="$mount_dir/.DS_Store"
  local complaints=0

  if [[ ! -d "$background_dir" ]]; then
    echo "release artifact styling warning: DMG has no $KUROTTY_DMG_BACKGROUND_DIR folder" >&2
    complaints=1
  elif [[ ! -f "$background_dir/background.tiff" && ! -f "$background_dir/background@2x.png" ]]; then
    # Either rendition is legitimate; which one was used depends on whether
    # tiffutil was available when the DMG was built.
    echo "release artifact styling warning: $KUROTTY_DMG_BACKGROUND_DIR holds no usable background" >&2
    complaints=1
  fi

  if [[ ! -s "$settings" ]]; then
    echo "release artifact styling warning: DMG has no .DS_Store window settings" >&2
    complaints=1
  else
    # Finder writes the window rect and the icon-view options as ASCII inside the
    # .DS_Store bplist blobs, so the settings can be read back without asking
    # Finder anything. Only the window *size* is asserted: Finder stores the
    # origin flipped into screen-bottom coordinates, which makes it depend on the
    # display of whatever machine built the DMG.
    local expected_size
    expected_size="{$KUROTTY_DMG_WINDOW_WIDTH, $KUROTTY_DMG_WINDOW_HEIGHT}}"
    if ! LC_ALL=C grep -qa -- "$expected_size" "$settings"; then
      echo "release artifact styling warning: .DS_Store does not record a $KUROTTY_DMG_WINDOW_WIDTH x $KUROTTY_DMG_WINDOW_HEIGHT window" >&2
      complaints=1
    fi
    if ! LC_ALL=C grep -qa -- 'backgroundImageAlias' "$settings"; then
      echo "release artifact styling warning: .DS_Store records no background picture" >&2
      complaints=1
    fi
    if ! LC_ALL=C grep -qa -- 'ShowToolbar' "$settings"; then
      echo "release artifact styling warning: .DS_Store records no toolbar/sidebar state" >&2
      complaints=1
    fi
    # One Iloc record per placed item. Without both, the icons fall back to
    # Finder's grid and land on top of the chevrons.
    if [[ "$(LC_ALL=C grep -oa -- 'Iloc' "$settings" | wc -l | tr -d ' ')" -lt 2 ]]; then
      echo "release artifact styling warning: .DS_Store does not position both install items" >&2
      complaints=1
    fi
  fi

  if [[ "$complaints" == "0" ]]; then
    echo "release artifact styling verified: install window is configured"
  else
    echo "release artifact styling incomplete: DMG will open unstyled (not fatal)" >&2
  fi

  # Explicit, because the caller runs under `set -e` and this must never be the
  # thing that fails a release.
  return 0
}

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

report_dmg_styling "$MOUNT_DIR"

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
