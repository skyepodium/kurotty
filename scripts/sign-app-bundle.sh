#!/usr/bin/env bash

# Sign Sparkle from the innermost helpers outward. Sparkle's installer launcher
# must keep its own bundle metadata; recursive --deep signing can rewrite nested
# services in ways that prevent macOS Authorization Services from identifying
# the process that is requesting an update.
sign_kurotty_app_bundle() {
  local app_bundle="${1:?app bundle path is required}"
  local sign_identity="${2:?signing identity is required}"
  local sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
  local preserve_sparkle_metadata="--preserve-metadata=identifier,entitlements"

  sign_code() {
    local target="$1"
    shift

    if [[ "$sign_identity" == "-" ]]; then
      codesign --force --sign - "$@" "$target"
    else
      codesign --force --timestamp --options runtime --sign "$sign_identity" "$@" "$target"
    fi
  }

  sign_sparkle_component() {
    local target="$1"
    [[ -e "$target" ]] || {
      echo "Sparkle signing failed: missing component: $target" >&2
      return 1
    }
    sign_code "$target" "$preserve_sparkle_metadata"
  }

  sign_sparkle_component "$sparkle_framework/Versions/Current/XPCServices/Downloader.xpc"
  sign_sparkle_component "$sparkle_framework/Versions/Current/XPCServices/Installer.xpc"
  sign_sparkle_component "$sparkle_framework/Versions/Current/Updater.app"
  sign_sparkle_component "$sparkle_framework/Versions/Current/Autoupdate"
  sign_sparkle_component "$sparkle_framework"

  sign_code "$app_bundle/Contents/Resources/libkurotty_core.dylib"
  sign_code "$app_bundle"
}
