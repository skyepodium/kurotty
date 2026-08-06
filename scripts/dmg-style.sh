#!/usr/bin/env bash

# Install-window design for the release DMG.
#
# Sourced rather than executed, like iconset.sh, so package-release.sh and
# verify-release-artifact.sh read one set of numbers: if the window geometry
# moves, the check that asserts it moved with it.
#
# Everything here is best-effort. Styling a DMG means driving Finder over
# AppleScript, which on a GitHub Actions runner can fail outright (no Automation
# permission) or, worse, block forever waiting on a Finder that never becomes
# ready. An unstyled DMG that ships beats a release workflow that hangs, so the
# caller treats every failure below as a skip and says so in the log.

KUROTTY_DMG_BACKGROUND_DIR=".background"
KUROTTY_DMG_WINDOW_LEFT=200
KUROTTY_DMG_WINDOW_TOP=120
KUROTTY_DMG_WINDOW_WIDTH=800
# Point size of the picture generate-dmg-background.swift renders. Everything
# below is expressed in the same top-left coordinates that picture is drawn in.
KUROTTY_DMG_BACKGROUND_HEIGHT=400
# Finder's `bounds` is the window *frame*, title bar included, while the
# background fills only the content area beneath it. Setting the frame to the
# picture's height leaves the content 32pt short, and Finder answers that by
# making the window scroll — which can hide the Applications folder below the
# fold. `NSWindow.frameRect(forContentRect:styleMask:)` reports 32pt for a titled
# window on macOS 14 through 26. Erring large only leaves a sliver of canvas
# colour under the picture; erring small brings the scrollbar back.
KUROTTY_DMG_TITLEBAR_HEIGHT=32
KUROTTY_DMG_WINDOW_HEIGHT=$((KUROTTY_DMG_BACKGROUND_HEIGHT + KUROTTY_DMG_TITLEBAR_HEIGHT))
KUROTTY_DMG_ICON_SIZE=176
KUROTTY_DMG_TEXT_SIZE=14
# Finder's `position` is the centre of the icon, not its top-left corner. The
# label sits below the icon and outside its frame, so the row has to stop well
# short of the bottom edge; generate-dmg-background.swift puts its chevrons on
# this same y.
KUROTTY_DMG_APP_ICON_X=200
KUROTTY_DMG_APP_ICON_Y=240
KUROTTY_DMG_APPLICATIONS_ICON_X=600
KUROTTY_DMG_APPLICATIONS_ICON_Y=240
# Wall-clock ceiling for the Finder conversation. Generous enough that a slow
# runner still finishes, short enough that a wedged Finder costs one minute of
# release time instead of the workflow's whole timeout.
KUROTTY_DMG_STYLE_TIMEOUT_SECONDS="${KUROTTY_DMG_STYLE_TIMEOUT_SECONDS:-90}"
# Set by render_kurotty_dmg_background to whichever rendition Finder should read.
KUROTTY_DMG_BACKGROUND_FILE="background.tiff"

# Renders the background into <volume-root>/.background at both scales.
render_kurotty_dmg_background() {
  local scripts_dir="$1"
  local volume_root="$2"
  local background_dir="$volume_root/$KUROTTY_DMG_BACKGROUND_DIR"

  mkdir -p "$background_dir"
  "$scripts_dir/generate-dmg-background.swift" "$background_dir/background.png" 1
  "$scripts_dir/generate-dmg-background.swift" "$background_dir/background@2x.png" 2

  # Finder points at exactly one file, so the two renditions are combined into a
  # multi-resolution TIFF. Falling back to the @2x PNG alone still lays out
  # correctly because the renderer stamps it at 144 dpi, so AppKit reads it as
  # 800x400 points; it just costs a needlessly large image on 1x displays.
  if command -v tiffutil >/dev/null 2>&1 &&
    tiffutil -cathidpicheck \
      "$background_dir/background.png" \
      "$background_dir/background@2x.png" \
      -out "$background_dir/background.tiff" >/dev/null 2>&1; then
    KUROTTY_DMG_BACKGROUND_FILE="background.tiff"
  else
    KUROTTY_DMG_BACKGROUND_FILE="background@2x.png"
    echo "DMG styling: tiffutil unavailable, using $KUROTTY_DMG_BACKGROUND_FILE for the background." >&2
  fi
}

# Drops whichever renditions the composed TIFF made redundant. Finder reads one
# file; the other two would be a megabyte of dead weight in every download.
prune_kurotty_dmg_background_sources() {
  local volume_root="$1"
  local background_dir="$volume_root/$KUROTTY_DMG_BACKGROUND_DIR"

  if [[ "$KUROTTY_DMG_BACKGROUND_FILE" == "background.tiff" ]]; then
    rm -f "$background_dir/background.png" "$background_dir/background@2x.png"
  fi
}

# Runs a command under a hard wall-clock limit. macOS ships no timeout(1), and
# perl's alarm survives exec, so the SIGALRM lands on the real process rather
# than on a wrapper that would leave it running.
run_with_kurotty_dmg_timeout() {
  local seconds="$1"
  shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
}

# Configures the mounted volume's Finder window. Returns nonzero on any failure,
# including timeout; the caller must not treat that as fatal.
style_kurotty_dmg_window() {
  local mount_point="$1"
  local volume_name
  volume_name="$(basename "$mount_point")"

  if [[ "${KUROTTY_SKIP_DMG_STYLING:-0}" == "1" ]]; then
    echo "DMG styling: skipped because KUROTTY_SKIP_DMG_STYLING=1."
    return 1
  fi

  if ! command -v osascript >/dev/null 2>&1; then
    echo "DMG styling: skipped because osascript is unavailable." >&2
    return 1
  fi

  local status=0
  run_with_kurotty_dmg_timeout "$KUROTTY_DMG_STYLE_TIMEOUT_SECONDS" \
    osascript - \
    "$volume_name" \
    "$KUROTTY_DMG_BACKGROUND_DIR:$KUROTTY_DMG_BACKGROUND_FILE" \
    "$KUROTTY_DMG_WINDOW_LEFT" \
    "$KUROTTY_DMG_WINDOW_TOP" \
    "$((KUROTTY_DMG_WINDOW_LEFT + KUROTTY_DMG_WINDOW_WIDTH))" \
    "$((KUROTTY_DMG_WINDOW_TOP + KUROTTY_DMG_WINDOW_HEIGHT))" \
    "$KUROTTY_DMG_ICON_SIZE" \
    "$KUROTTY_DMG_TEXT_SIZE" \
    "$KUROTTY_DMG_APP_ICON_X" \
    "$KUROTTY_DMG_APP_ICON_Y" \
    "$KUROTTY_DMG_APPLICATIONS_ICON_X" \
    "$KUROTTY_DMG_APPLICATIONS_ICON_Y" <<'APPLESCRIPT' || status=$?
on run argv
  set volumeName to item 1 of argv
  set backgroundPath to item 2 of argv
  set windowBounds to {item 3 of argv as integer, item 4 of argv as integer, ¬
    item 5 of argv as integer, item 6 of argv as integer}
  set iconSize to item 7 of argv as integer
  set labelSize to item 8 of argv as integer
  set appPosition to {item 9 of argv as integer, item 10 of argv as integer}
  set applicationsPosition to {item 11 of argv as integer, item 12 of argv as integer}

  tell application "Finder"
    tell disk volumeName
      open
      set installWindow to container window
      set current view of installWindow to icon view
      set toolbar visible of installWindow to false
      set the bounds of installWindow to windowBounds
      -- Cosmetic and version-sensitive; a Finder that refuses either of these
      -- should still get the background and the icon positions.
      try
        set statusbar visible of installWindow to false
      end try
      try
        set sidebar width of installWindow to 0
      end try

      set viewOptions to the icon view options of installWindow
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to iconSize
      set text size of viewOptions to labelSize
      set background picture of viewOptions to file backgroundPath

      set position of item "kurotty.app" of installWindow to appPosition
      set position of item "Applications" of installWindow to applicationsPosition

      update without registering applications
      -- Finder writes .DS_Store lazily; closing immediately after the update can
      -- lose the settings we just made.
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT

  if [[ "$status" != "0" ]]; then
    if [[ "$status" == "142" ]]; then
      echo "DMG styling: skipped, Finder did not respond within ${KUROTTY_DMG_STYLE_TIMEOUT_SECONDS}s." >&2
    else
      echo "DMG styling: skipped, osascript exited $status." >&2
    fi
    return "$status"
  fi

  # The window settings only reach the image once .DS_Store is flushed to disk.
  sync
  return 0
}

# Finder can keep the volume busy for a moment after its window closes, which is
# a race the unstyled path never had to run. Retry before forcing, and only
# force as a last resort so a genuinely stuck device still fails the build.
detach_kurotty_dmg() {
  local device="$1"
  local attempt
  for attempt in 1 2 3; do
    if hdiutil detach "$device" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  hdiutil detach "$device" -force >/dev/null
}
