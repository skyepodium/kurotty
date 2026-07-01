# Kurotty

<p align="center">
  <img src="kurotty.png" alt="Kurotty" width="400" height="400">
</p>

<p align="center">
  <img src="kurotty-preview.gif" alt="Kurotty preview" width="700">
</p>

Kurotty is a macOS-first terminal emulator built with Swift/AppKit, Zig, and Metal.

Kurotty is currently an early developer build. Download the latest alpha release if you only want to try the app; build from source if you want to contribute.

[Download](#download) · [Features](#features) · [Build From Source](#build-from-source) · [License](#license)

## Download

Kurotty ships as a notarized Universal DMG for Intel and Apple Silicon Macs.

[Download the latest Kurotty DMG](https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg)

Open the DMG, drag `kurotty.app` to `Applications`, then launch it from `/Applications`. Release notes and older builds are available on [GitHub Releases](https://github.com/skyepodium/kurotty/releases).

To download and install from a shell:

```sh
curl -fL -o kurotty-macos-universal.dmg \
  https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg
curl -fL -O \
  https://github.com/skyepodium/kurotty/releases/latest/download/SHA256SUMS
grep '  kurotty-macos-universal.dmg$' SHA256SUMS | shasum -a 256 -c -

MOUNT_DIR="$(mktemp -d)"
hdiutil attach kurotty-macos-universal.dmg -mountpoint "$MOUNT_DIR" -nobrowse
ditto "$MOUNT_DIR/kurotty.app" /Applications/kurotty.app
hdiutil detach "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
open /Applications/kurotty.app
```

The stable download URL always points to the latest release. Each release also includes:

- `kurotty-<version>-macos-universal.dmg`
- `kurotty-macos-universal.dmg`
- `SHA256SUMS`
- `appcast.xml` for automatic updates

On first launch, macOS may ask for notification permission because Kurotty supports terminal-triggered task notifications.

## Features

- Native macOS tabs, split panes, menus, keyboard input, IME, clipboard, and preferences.
- Metal rendering for glyphs, backgrounds, cursor, underline, and strikethrough.
- Theme presets, scrollback, and editable JSON settings.
- Terminal styling support for 16-color, 256-color, truecolor, dim, inverse, underline, and strikethrough.
- OSC title, working-directory, color query, and iTerm2-compatible notifications.

Notification example:

```sh
printf '\e]9;Task finished\a'
```

Kurotty shows OSC 9 messages as macOS `Alert` notifications with the app icon and the message body.

## Build From Source

This path is for contributors and local testing.

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- Zig

```sh
git clone https://github.com/skyepodium/kurotty.git
cd kurotty
zig build
swift run kurotty
```

To install a local app bundle:

```sh
export KUROTTY_LOCAL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/install-app.sh
open /Applications/kurotty.app
```

If you do not set `KUROTTY_LOCAL_SIGN_IDENTITY`, local install uses ad-hoc signing.

To create a local Universal DMG:

```sh
./scripts/package-release.sh
```

The script writes:

- `dist/kurotty-$(cat VERSION)-macos-universal.dmg`
- `dist/kurotty-macos-universal.dmg`
- `dist/SHA256SUMS`
- `dist/appcast.xml` when Sparkle signing is configured

To publish an alpha release from `main`:

```sh
git switch main
git pull --ff-only
swift test
git tag "v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

The release workflow builds, signs, notarizes, staples, generates the Sparkle appcast, and uploads the release assets to GitHub Releases. Bump `VERSION` first, merge the release commit to `main`, then tag from `main`.

Developer notes live in `docs/`.

## License

Kurotty is released under the MIT License.
