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

Download the latest alpha Universal DMG directly:

[Download Kurotty for macOS](https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg)

It supports Intel and Apple Silicon Macs. Release notes and older builds are available on [GitHub Releases](https://github.com/skyepodium/kurotty/releases).

Release asset names:

- `kurotty-macos-universal.dmg`
- `kurotty-<version>-macos-universal.dmg`
- `SHA256SUMS`

```sh
curl -LO https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg
curl -LO https://github.com/skyepodium/kurotty/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS
open kurotty-macos-universal.dmg
open /Applications/kurotty.app
```

Notes:

- This is an alpha build.
- Release builds are packaged as a Universal DMG for Intel and Apple Silicon Macs.
- macOS may warn that it cannot verify this app if it was built without Apple notarization. This is expected for unsigned/dev builds and can be bypassed:

  ```sh
  xattr -dr com.apple.quarantine kurotty-macos-universal.dmg
  open kurotty-macos-universal.dmg
  xattr -dr com.apple.quarantine /Applications/kurotty.app
  open /Applications/kurotty.app
  ```

  Or right-click the app in Finder and choose **Open**.

  For public releases, this warning should not appear when the release workflow runs with:
  - `KUROTTY_RELEASE_SIGN_IDENTITY`
  - `KUROTTY_NOTARY_PROFILE` (or Apple ID notarization credentials)

- On first launch, macOS may ask for notification permission because Kurotty supports terminal-triggered task notifications.

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
./scripts/install-app.sh
open /Applications/kurotty.app
```

To create the same Universal DMG locally:

```sh
./scripts/package-release.sh
```

The script writes:

- `dist/kurotty-$(cat VERSION)-macos-universal.dmg`
- `dist/SHA256SUMS`

To publish an alpha release from `main`:

```sh
git switch main
git pull --ff-only
git tag "v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

The release workflow builds a Universal DMG and uploads it to GitHub Releases. Bump `VERSION` first, then tag from `main`. Set Developer ID and notarization secrets in GitHub Actions when you want a fully signed and notarized DMG.

Developer notes live in `docs/`.

## License

Kurotty is released under the MIT License.
