#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${KUROTTY_UPDATE_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install-app.sh"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package-release.sh"
SIGNING_SCRIPT="$ROOT_DIR/scripts/sign-app-bundle.sh"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-release-artifact.sh"

fail() {
  echo "update contract: $*" >&2
  exit 1
}

for path in "$INSTALL_SCRIPT" "$PACKAGE_SCRIPT" "$SIGNING_SCRIPT" "$VERIFY_SCRIPT"; do
  [[ -f "$path" ]] || fail "missing required script: $path"
done

if grep -En 'codesign .*--force.*--deep|codesign .*--deep.*--force' \
  "$INSTALL_SCRIPT" "$PACKAGE_SCRIPT" "$SIGNING_SCRIPT"; then
  fail "--deep may verify a finished bundle, but must never create or replace a signature"
fi

for component in \
  'XPCServices/Downloader.xpc' \
  'XPCServices/Installer.xpc' \
  'Updater.app' \
  'Autoupdate'; do
  grep -Fq "$component" "$SIGNING_SCRIPT" || fail "Sparkle signing omits $component"
done

grep -Fq -- '--preserve-metadata=identifier,entitlements' "$SIGNING_SCRIPT" || \
  fail "Sparkle helper signing must preserve identifiers and entitlements"
grep -Fq 'sign_kurotty_app_bundle "$APP_BUNDLE" "$SIGN_IDENTITY"' "$INSTALL_SCRIPT" || \
  fail "local install bypasses the shared signing contract"
grep -Fq 'sign_kurotty_app_bundle "$APP_BUNDLE" "$SIGN_IDENTITY"' "$PACKAGE_SCRIPT" || \
  fail "release packaging bypasses the shared signing contract"

guard_line="$(grep -nF 'Refusing to replace a running app bundle' "$INSTALL_SCRIPT" | cut -d: -f1 | head -1)"
replace_line="$(grep -nF 'rm -rf "$INSTALLED_APP"' "$INSTALL_SCRIPT" | cut -d: -f1 | head -1)"
[[ -n "$guard_line" && -n "$replace_line" && "$guard_line" -lt "$replace_line" ]] || \
  fail "the running-app guard must execute before the installed bundle is replaced"

grep -Fq 'verify_sparkle_signing "$COPIED_APP"' "$VERIFY_SCRIPT" || \
  fail "release verification omits Sparkle nested-code checks"
grep -Fq 'Sparkle signing identity mismatch' "$VERIFY_SCRIPT" || \
  fail "release verification does not enforce signing-team continuity"

echo "update contract: invariants hold"
